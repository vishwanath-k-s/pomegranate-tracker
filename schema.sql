-- ============================================================================
-- HOSAHALLI POMEGRANATE DYNAMIC TRACKER - IDEMPOTENT POSTGRESQL / SUPABASE SCHEMA
-- Coordinates: 14.661830, 76.454375 | 3 Acres | 1,500 Plants (10x8 ft)
-- Canonical Harvest Horizon: 190 DAD (2027-02-21 from 2026-08-15 Ethrel)
-- ============================================================================

-- Drop legacy unused table (Item C23)
DROP TABLE IF EXISTS public.weather_and_scouting_logs;

-- 1. ORCHARD CONFIGURATION (Idempotent with UNIQUE name — Item C18 & D29)
CREATE TABLE IF NOT EXISTS public.orchard_blocks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL UNIQUE DEFAULT 'Hosahalli Pomegranate Block (3 Acres)',
    gps_lat NUMERIC(9,6) NOT NULL DEFAULT 14.661830,
    gps_lon NUMERIC(9,6) NOT NULL DEFAULT 76.454375,
    area_acres NUMERIC(5,2) NOT NULL DEFAULT 3.00,
    plant_count INT NOT NULL DEFAULT 1500,
    spacing_ft TEXT DEFAULT '10x8',
    ethrel_spray_date DATE NOT NULL DEFAULT '2026-08-15',
    expected_harvest_date DATE NOT NULL DEFAULT '2027-02-21', -- 190 DAD canonical horizon
    default_drums_per_spray NUMERIC(4,1) NOT NULL DEFAULT 7.0,
    manual_stage_override TEXT CHECK (manual_stage_override IN ('LEMON', 'GUAVA', 'COLOR_INIT', 'HARVEST_READY'))
);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'orchard_blocks_name_key'
    ) THEN
        DELETE FROM public.orchard_blocks a USING public.orchard_blocks b
        WHERE a.ctid < b.ctid AND a.name = b.name;
        ALTER TABLE public.orchard_blocks ADD CONSTRAINT orchard_blocks_name_key UNIQUE (name);
    END IF;
END $$;

INSERT INTO public.orchard_blocks (name, gps_lat, gps_lon, area_acres, plant_count, ethrel_spray_date, expected_harvest_date)
VALUES ('Hosahalli Pomegranate Block (3 Acres)', 14.661830, 76.454375, 3.00, 1500, '2026-08-15', '2027-02-21')
ON CONFLICT (name) DO UPDATE SET
    gps_lat = EXCLUDED.gps_lat,
    gps_lon = EXCLUDED.gps_lon,
    area_acres = EXCLUDED.area_acres,
    plant_count = EXCLUDED.plant_count,
    ethrel_spray_date = EXCLUDED.ethrel_spray_date,
    expected_harvest_date = EXCLUDED.expected_harvest_date;

-- 2. MASTER INPUTS CATALOG (With Separate Foliar/Drip Units & Full FCO Grades — Items C19, C20, C21)
CREATE TABLE IF NOT EXISTS public.inputs_catalog (
    id TEXT PRIMARY KEY,
    name_en TEXT NOT NULL,
    name_kn TEXT NOT NULL,
    category TEXT NOT NULL CHECK (category IN ('FERTIGATION', 'FUNGICIDE', 'INSECTICIDE', 'BACTERICIDE', 'BIOSTIMULANT', 'ADJUVANT')),
    active_ingredient TEXT NOT NULL,
    popular_brands TEXT,
    irac_frac_group TEXT,
    formulation_type TEXT DEFAULT 'SC',
    application_method TEXT NOT NULL CHECK (application_method IN ('DRIP', 'FOLIAR', 'BOTH')),
    base_dose_per_liter NUMERIC(8,3),
    foliar_dose_unit TEXT CHECK (foliar_dose_unit IN ('ml', 'g')),
    base_dose_per_acre NUMERIC(8,3),
    drip_dose_unit TEXT CHECK (drip_dose_unit IN ('L', 'kg')),
    unit TEXT NOT NULL CHECK (unit IN ('ml', 'g', 'kg', 'L')),
    standard_pack_sizes TEXT,
    procurement_criticality TEXT NOT NULL DEFAULT 'FLEXIBLE'
        CHECK (procurement_criticality IN ('FLEXIBLE', 'CRITICAL_MUST_SOURCE')),
    dealer_warning_en TEXT,
    phi_days INT NOT NULL DEFAULT 0,
    is_copper_compound BOOLEAN DEFAULT FALSE,
    incompatible_with_copper BOOLEAN DEFAULT FALSE,
    incompatible_with_calcium BOOLEAN DEFAULT FALSE,
    contains_nitrogen BOOLEAN DEFAULT FALSE,
    n_pct NUMERIC(5,2) DEFAULT 0,
    p_pct NUMERIC(5,2) DEFAULT 0,
    k_pct NUMERIC(5,2) DEFAULT 0,
    ca_pct NUMERIC(5,2) DEFAULT 0,
    mg_pct NUMERIC(5,2) DEFAULT 0,
    b_pct NUMERIC(5,2) DEFAULT 0
);

ALTER TABLE public.inputs_catalog ADD COLUMN IF NOT EXISTS formulation_type TEXT DEFAULT 'SC';
ALTER TABLE public.inputs_catalog ADD COLUMN IF NOT EXISTS foliar_dose_unit TEXT CHECK (foliar_dose_unit IN ('ml', 'g'));
ALTER TABLE public.inputs_catalog ADD COLUMN IF NOT EXISTS drip_dose_unit TEXT CHECK (drip_dose_unit IN ('L', 'kg'));
ALTER TABLE public.inputs_catalog ADD COLUMN IF NOT EXISTS n_pct NUMERIC(5,2) DEFAULT 0;
ALTER TABLE public.inputs_catalog ADD COLUMN IF NOT EXISTS p_pct NUMERIC(5,2) DEFAULT 0;
ALTER TABLE public.inputs_catalog ADD COLUMN IF NOT EXISTS k_pct NUMERIC(5,2) DEFAULT 0;
ALTER TABLE public.inputs_catalog ADD COLUMN IF NOT EXISTS ca_pct NUMERIC(5,2) DEFAULT 0;
ALTER TABLE public.inputs_catalog ADD COLUMN IF NOT EXISTS mg_pct NUMERIC(5,2) DEFAULT 0;
ALTER TABLE public.inputs_catalog ADD COLUMN IF NOT EXISTS b_pct NUMERIC(5,2) DEFAULT 0;

-- 3. SHED LEFTOVER BALANCE (Item C21: explicit unit column)
CREATE TABLE IF NOT EXISTS public.shed_leftovers (
    input_id TEXT PRIMARY KEY REFERENCES public.inputs_catalog(id) ON DELETE CASCADE,
    leftover_qty NUMERIC(10,2) NOT NULL DEFAULT 0,
    unit TEXT DEFAULT 'kg',
    updated_at TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE public.shed_leftovers ADD COLUMN IF NOT EXISTS unit TEXT DEFAULT 'kg';

-- 4. STORE COUNTER SUBSTITUTION MATRIX
CREATE TABLE IF NOT EXISTS public.substitution_rules (
    id SERIAL PRIMARY KEY,
    primary_input_id TEXT REFERENCES public.inputs_catalog(id) ON DELETE CASCADE,
    substitute_input_id TEXT REFERENCES public.inputs_catalog(id) ON DELETE CASCADE,
    target_purpose TEXT NOT NULL,
    priority_rank INT NOT NULL DEFAULT 1,
    adjustment_note_en TEXT,
    UNIQUE (primary_input_id, substitute_input_id)
);

-- 5. BASELINE 30-WEEK SCHEDULE TEMPLATE
CREATE TABLE IF NOT EXISTS public.baseline_schedule_template (
    id SERIAL PRIMARY KEY,
    week_number INT NOT NULL,
    dad_start INT NOT NULL,
    dad_end INT NOT NULL,
    day_of_week INT NOT NULL,
    task_type TEXT NOT NULL CHECK (task_type IN ('DRIP_MON_THU', 'DRIP_SAT', 'FOLIAR_SPRAY', 'STANDALONE_COPPER')),
    stage_name TEXT NOT NULL,
    target_description TEXT NOT NULL,
    recipe_items JSONB NOT NULL
);

-- 6. DYNAMIC DAILY TASK QUEUE (Items B15, C16, C22, C25)
CREATE TABLE IF NOT EXISTS public.daily_task_queue (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    block_id UUID REFERENCES public.orchard_blocks(id) ON DELETE SET NULL,
    template_id INT REFERENCES public.baseline_schedule_template(id) ON DELETE SET NULL,
    env TEXT NOT NULL DEFAULT 'PROD' CHECK (env IN ('PROD', 'DEV')),
    originally_scheduled_date DATE NOT NULL,
    current_scheduled_date DATE NOT NULL,
    effective_dad INT NOT NULL,
    task_type TEXT NOT NULL CHECK (task_type IN ('DRIP_MON_THU', 'DRIP_SAT', 'FOLIAR_SPRAY', 'STANDALONE_COPPER')),
    trigger_source TEXT NOT NULL DEFAULT 'BASELINE'
        CHECK (trigger_source IN (
            'BASELINE', 'RAIN_EMERGENCY', 'EL_NINO_COLOR_BOOST', 'HEAT_CRACK_SHIELD',
            'SCOUTING_CURATIVE', 'MANUAL_ENTRY', 'SPLIT_REMAINDER', 'KEEP_NOTE_HISTORY'
        )),
    status TEXT NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING', 'SHOPPING_NEEDED', 'HOLD_WEATHER', 'COMPLETED', 'DELAYED', 'SKIPPED')),
    drum_liters INT NOT NULL DEFAULT 200,
    drums_count NUMERIC(4,1) NOT NULL DEFAULT 7.0,
    resolved_recipe JSONB NOT NULL,
    delay_reason TEXT
        CHECK (delay_reason IN (
            'RAIN', 'NO_POWER', 'NO_LABOR', 'SOURCING_FROM_OTHER_TOWN',
            'CURATIVE_COOLDOWN', 'COPPER_COOLDOWN_5D', 'NEW_CARD_SAFE_GAP',
            'RESCHEDULED', 'CASCADE_ALL', 'MIN_GAP_GUARD', 'SPLIT_REMAINDER'
        )),
    cost_rs NUMERIC(10,2) DEFAULT 0,
    version_int INT NOT NULL DEFAULT 1,
    custom_title_en TEXT,
    custom_title_kn TEXT,
    executed_at TIMESTAMPTZ,
    notes TEXT,
    updated_by TEXT DEFAULT 'Vishwanath',
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Ensure existing daily_task_queue table has all columns & updated CHECK constraints (Items B15, C16, C22)
ALTER TABLE public.daily_task_queue ADD COLUMN IF NOT EXISTS env TEXT NOT NULL DEFAULT 'PROD';
ALTER TABLE public.daily_task_queue ADD COLUMN IF NOT EXISTS drum_liters INT NOT NULL DEFAULT 200;
ALTER TABLE public.daily_task_queue ADD COLUMN IF NOT EXISTS drums_count NUMERIC(4,1) NOT NULL DEFAULT 7.0;
ALTER TABLE public.daily_task_queue ADD COLUMN IF NOT EXISTS cost_rs NUMERIC(10,2) DEFAULT 0;
ALTER TABLE public.daily_task_queue ADD COLUMN IF NOT EXISTS version_int INT NOT NULL DEFAULT 1;
ALTER TABLE public.daily_task_queue ADD COLUMN IF NOT EXISTS custom_title_en TEXT;
ALTER TABLE public.daily_task_queue ADD COLUMN IF NOT EXISTS custom_title_kn TEXT;
ALTER TABLE public.daily_task_queue ADD COLUMN IF NOT EXISTS updated_by TEXT DEFAULT 'Vishwanath';
ALTER TABLE public.daily_task_queue ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();

ALTER TABLE public.daily_task_queue DROP CONSTRAINT IF EXISTS daily_task_queue_task_type_check;
ALTER TABLE public.daily_task_queue ADD CONSTRAINT daily_task_queue_task_type_check
    CHECK (task_type IN ('DRIP_MON_THU', 'DRIP_SAT', 'FOLIAR_SPRAY', 'STANDALONE_COPPER'));

ALTER TABLE public.daily_task_queue DROP CONSTRAINT IF EXISTS daily_task_queue_trigger_source_check;
ALTER TABLE public.daily_task_queue ADD CONSTRAINT daily_task_queue_trigger_source_check
    CHECK (trigger_source IN (
        'BASELINE', 'RAIN_EMERGENCY', 'EL_NINO_COLOR_BOOST', 'HEAT_CRACK_SHIELD',
        'SCOUTING_CURATIVE', 'MANUAL_ENTRY', 'SPLIT_REMAINDER', 'KEEP_NOTE_HISTORY'
    ));

ALTER TABLE public.daily_task_queue DROP CONSTRAINT IF EXISTS daily_task_queue_delay_reason_check;
ALTER TABLE public.daily_task_queue ADD CONSTRAINT daily_task_queue_delay_reason_check
    CHECK (delay_reason IS NULL OR delay_reason IN (
        'RAIN', 'NO_POWER', 'NO_LABOR', 'SOURCING_FROM_OTHER_TOWN',
        'CURATIVE_COOLDOWN', 'COPPER_COOLDOWN_5D', 'NEW_CARD_SAFE_GAP',
        'RESCHEDULED', 'CASCADE_ALL', 'MIN_GAP_GUARD', 'SPLIT_REMAINDER'
    ));

CREATE INDEX IF NOT EXISTS idx_daily_task_queue_env_status_date
    ON public.daily_task_queue (env, status, current_scheduled_date);

-- Auto-increment version_int & stamp updated_at on every task update (Item C25)
CREATE OR REPLACE FUNCTION public.trg_daily_task_queue_before_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
    NEW.updated_at := NOW();
    NEW.version_int := COALESCE(OLD.version_int, 1) + 1;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_daily_task_queue_meta ON public.daily_task_queue;
CREATE TRIGGER trg_daily_task_queue_meta
BEFORE UPDATE ON public.daily_task_queue
FOR EACH ROW
EXECUTE FUNCTION public.trg_daily_task_queue_before_update();

-- 7. WEATHER TELEMETRY & FARM RAIN LOGS
CREATE TABLE IF NOT EXISTS public.weather_telemetry_history (
    log_date DATE PRIMARY KEY,
    temp_max_c NUMERIC(4,1) NOT NULL DEFAULT 30.5,
    temp_min_c NUMERIC(4,1) NOT NULL DEFAULT 18.5,
    humidity_mean_pct INT NOT NULL DEFAULT 60,
    rain_mm NUMERIC(5,1) NOT NULL DEFAULT 0,
    daily_gdd NUMERIC(5,2) NOT NULL DEFAULT 14.5,
    disease_risk_score INT NOT NULL DEFAULT 25,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.farm_rain_logs (
    log_date DATE PRIMARY KEY,
    rain_mm NUMERIC(5,1) NOT NULL DEFAULT 0,
    rain_label TEXT,
    logged_by TEXT DEFAULT 'Vishwanath',
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 8. PREVIOUSLY UNDEFINED TABLES: COMMERCIAL BRANDS, AUDIT LOG & APP USERS (Item C17)
CREATE TABLE IF NOT EXISTS public.commercial_brands_directory (
    id SERIAL PRIMARY KEY,
    brand_name TEXT NOT NULL,
    company_name TEXT DEFAULT 'Store Brand',
    input_id TEXT REFERENCES public.inputs_catalog(id) ON DELETE CASCADE,
    primary_use_en TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.activity_audit_log (
    id SERIAL PRIMARY KEY,
    env TEXT NOT NULL DEFAULT 'PROD' CHECK (env IN ('PROD', 'DEV')),
    actor_name TEXT NOT NULL DEFAULT 'Vishwanath',
    action_type TEXT NOT NULL,
    task_summary TEXT,
    details TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_activity_audit_log_env_created
    ON public.activity_audit_log (env, created_at DESC);

CREATE TABLE IF NOT EXISTS public.app_users (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    auth_user_id UUID,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

INSERT INTO public.app_users (name)
VALUES ('Vishwanath')
ON CONFLICT (name) DO NOTHING;

-- Enable RLS on the 3 newly added tables as well (Item A1)
ALTER TABLE public.commercial_brands_directory ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.activity_audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.app_users ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['commercial_brands_directory', 'activity_audit_log', 'app_users'] LOOP
        EXECUTE format('DROP POLICY IF EXISTS orchard_access_policy ON public.%I;', t);
        EXECUTE format(
            'CREATE POLICY orchard_access_policy ON public.%I FOR ALL TO authenticated, anon USING (true) WITH CHECK (true);',
            t
        );
    END LOOP;
END $$;

-- ============================================================================
-- IDEMPOTENT CATALOG & SUBSTITUTION SEEDS (Items C18, C19, C20, C21)
-- ============================================================================
INSERT INTO public.inputs_catalog (
    id, name_en, name_kn, category, active_ingredient, popular_brands, irac_frac_group, formulation_type,
    application_method, base_dose_per_liter, foliar_dose_unit, base_dose_per_acre, drip_dose_unit, unit, standard_pack_sizes,
    procurement_criticality, dealer_warning_en, phi_days, is_copper_compound, incompatible_with_copper, incompatible_with_calcium,
    contains_nitrogen, n_pct, p_pct, k_pct, ca_pct, mg_pct, b_pct
) VALUES
('WSF_00_52_34', '00:52:34 (MKP)', '00:52:34 — ಮೊನೊ ಪೊಟ್ಯಾಸಿಯಮ್ ಫಾಸ್ಫೇಟ್ (MKP)', 'FERTIGATION', 'Mono Potassium Phosphate', 'Haifa, Coromandel, IFFCO, Mahadhan', NULL, 'WSF', 'BOTH', 4.0, 'g', 3.5, 'kg', 'kg', '1kg, 25kg Bag', 'CRITICAL_MUST_SOURCE', 'Do NOT substitute with DAP or 19:19:19 during fruit sizing/color stages (excess Nitrogen ruins rind quality).', 0, FALSE, FALSE, TRUE, FALSE, 0, 52, 34, 0, 0, 0),
('WSF_00_00_50', '00:00:50 (SOP)', '00:00:50 — ಪೊಟ್ಯಾಸಿಯಮ್ ಸಲ್ಫೇಟ್ (SOP)', 'FERTIGATION', 'Potassium Sulphate (50% K2O)', 'SQM, Haifa, Mahadhan, IFFCO', NULL, 'WSF', 'BOTH', 5.0, 'g', 5.0, 'kg', 'kg', '1kg, 25kg Bag', 'CRITICAL_MUST_SOURCE', 'CRITICAL: Never accept Muriate of Potash (MOP / Red Potash) or 13:00:45 after 140 DAD. Chloride burns roots and Nitrate keeps skin green.', 0, FALSE, FALSE, TRUE, FALSE, 0, 0, 50, 0, 0, 0),
('WSF_13_00_45', '13:00:45 (Potassium Nitrate)', '13:00:45 — ಪೊಟ್ಯಾಸಿಯಮ್ ನೈಟ್ರೇಟ್', 'FERTIGATION', 'Potassium Nitrate', 'Haifa Multi-K, Coromandel, Mahadhan', NULL, 'WSF', 'BOTH', 4.0, 'g', 3.0, 'kg', 'kg', '1kg, 25kg Bag', 'FLEXIBLE', 'Safe to use only before 140 DAD. After 2,150 GDD / 140 DAD, switch strictly to 00:00:50.', 0, FALSE, FALSE, FALSE, TRUE, 13, 0, 45, 0, 0, 0),
('WSF_CALCIUM_NITRATE', 'Calcium Nitrate (Water Soluble)', 'ಕ್ಯಾಲ್ಸಿಯಂ ನೈಟ್ರೇಟ್ (15.5% N, 18.8% Ca)', 'FERTIGATION', '15.5% N + 18.8% Ca', 'YaraLiva Tropicote/Calcinit, Mahadhan', NULL, 'WSF', 'BOTH', 3.0, 'g', 3.5, 'kg', 'kg', '1kg, 10kg, 25kg Bag', 'CRITICAL_MUST_SOURCE', 'Must run alone in drip tank. Never mix with 00:52:34, 00:00:50, or MgSO4.', 0, FALSE, FALSE, FALSE, TRUE, 15.5, 0, 0, 18.8, 0, 0),
('WSF_MGSO4', 'Magnesium Sulphate (MgSO4)', 'ಮೆಗ್ನೀಸಿಯಮ್ ಸಲ್ಫೇಟ್ (MgSO4 - 9.6% Mg)', 'FERTIGATION', 'Magnesium Sulphate Heptahydrate', 'Any Standard Grade', NULL, 'WSF', 'BOTH', 2.0, 'g', 2.5, 'kg', 'kg', '1kg, 25kg Bag', 'FLEXIBLE', NULL, 0, FALSE, FALSE, TRUE, FALSE, 0, 0, 0, 0, 9.6, 0),
('BAC_COPPER_HYDROXIDE', 'Copper Hydroxide 53.8% DF', 'ಕಾಪರ್ ಹೈಡ್ರಾಕ್ಸೈಡ್ 53.8% DF', 'BACTERICIDE', 'Copper Hydroxide 53.8% DF', 'Kocide 2000, Hidrokop', 'FRAC-M01', 'DF', 'FOLIAR', 1.5, 'g', NULL, NULL, 'g', '250g, 500g', 'FLEXIBLE', 'If Kocide 2000 is unavailable, use Copper Oxychloride 50% WP at 2.5 g/L (500 g/drum). Spray standalone.', 7, TRUE, FALSE, FALSE, FALSE, 0, 0, 0, 0, 0, 0),
('BAC_COPPER_OXY', 'Copper Oxychloride 50% WP', 'ಕಾಪರ್ ಆಕ್ಸಿಕ್ಲೋರೈಡ್ 50% WP', 'BACTERICIDE', 'Copper Oxychloride 50% WP', 'Blitox, Blue Copper, Trucop', 'FRAC-M01', 'WP', 'FOLIAR', 2.5, 'g', NULL, NULL, 'g', '500g, 1kg', 'FLEXIBLE', 'Spray standalone with Bronopol (2.5 g/L = 500 g/drum). Do not mix with amino acids or insecticides.', 7, TRUE, FALSE, FALSE, FALSE, 0, 0, 0, 0, 0, 0),
('BAC_BRONOPOL', 'Bronopol 95% (Bactericide)', 'ಬ್ರೊನೊಪಾಲ್ 95% (ಬ್ಯಾಕ್ಟೀರಿಯಾ ನಾಶಕ)', 'BACTERICIDE', '2-Bromo-2-nitropropane-1,3-diol', 'Bactrinashak, Bronocil, Balwan', 'BACTERICIDE', 'SP', 'FOLIAR', 0.5, 'g', NULL, NULL, 'g', '50g, 100g', 'CRITICAL_MUST_SOURCE', 'Essential partner with Copper for Bacterial Blight. If unavailable, ask for Kasugamycin 3% SL (1.5 ml/L).', 7, FALSE, FALSE, FALSE, FALSE, 0, 0, 0, 0, 0, 0),
('BAC_KASUGA_COC', 'Conika (Kasugamycin 5% + COC 45% WP)', 'ಕಸುಗಾಮೈಸಿನ್ 5% + ಕಾಪರ್ ಆಕ್ಸಿಕ್ಲೋರೈಡ್ 45% WP', 'BACTERICIDE', 'Kasugamycin 5% + Copper Oxychloride 45% WP', 'Conika (Dhanuka)', 'FRAC-24+M01', 'WP', 'FOLIAR', 2.5, 'g', NULL, NULL, 'g', '250g, 500g', 'FLEXIBLE', 'NRCP Table 1 #9 dual bactericide; spray standalone.', 14, TRUE, FALSE, FALSE, FALSE, 0, 0, 0, 0, 0, 0),
('INS_SPINETORAM', 'Spinetoram 11.7% SC', 'ಸ್ಪೈನೆಟೊರಾಮ್ 11.7% SC', 'INSECTICIDE', 'Spinetoram 11.7% SC', 'Delegate (Corteva), Largo (Dhanuka)', 'IRAC-5', 'SC', 'FOLIAR', 0.8, 'ml', NULL, NULL, 'ml', '100ml, 180ml, 500ml', 'FLEXIBLE', 'Top choice for Thrips & Fruit Borer without triggering mite flare-ups.', 14, FALSE, TRUE, FALSE, FALSE, 0, 0, 0, 0, 0, 0),
('INS_CYANTRANILIPROLE', 'Cyantraniliprole 10.26% OD', 'ಸಯಾಂಟ್ರಾನಿಲಿಪ್ರೋಲ್ 10.26% OD', 'INSECTICIDE', 'Cyantraniliprole 10.26% OD', 'Benevia (FMC)', 'IRAC-28', 'OD', 'FOLIAR', 0.7, 'ml', NULL, NULL, 'ml', '90ml, 180ml, 450ml', 'FLEXIBLE', 'Controls both Thrips and Fruit Borer.', 14, FALSE, TRUE, FALSE, FALSE, 0, 0, 0, 0, 0, 0),
('INS_SPINOSAD', 'Spinosad 45% SC', 'ಸ್ಪೈನೋಸಾಡ್ 45% SC', 'INSECTICIDE', 'Spinosad 45% SC', 'Tracer (Corteva), Conserve', 'IRAC-5', 'SC', 'FOLIAR', 0.4, 'ml', NULL, NULL, 'ml', '75ml, 150ml', 'FLEXIBLE', 'CIB&RC / NRCP thrips alternative (0.35–0.5 ml/L = 70–100 ml/drum).', 7, FALSE, TRUE, FALSE, FALSE, 0, 0, 0, 0, 0, 0),
('INS_CHLORANTRANILIPROLE', 'Chlorantraniliprole 18.5% SC', 'ಕ್ಲೋರಾಂಟ್ರಾನಿಲಿಪ್ರೋಲ್ 18.5% SC', 'INSECTICIDE', 'Chlorantraniliprole 18.5% SC', 'Coragen (FMC), Cover', 'IRAC-28', 'SC', 'FOLIAR', 0.3, 'ml', NULL, NULL, 'ml', '60ml, 150ml', 'FLEXIBLE', 'Targets Fruit Borer caterpillars (0.3 ml/L preventive, 0.4 ml/L curative).', 14, FALSE, TRUE, FALSE, FALSE, 0, 0, 0, 0, 0, 0),
('INS_FENPYROXIMATE', 'Fenpyroximate 5% EC', 'ಫೆನ್‌ಪೈರಾಕ್ಸಿಮೇಟ್ 5% EC (ನುಸಿ ನಾಶಕ)', 'INSECTICIDE', 'Fenpyroximate 5% EC', 'Sedna, Mitigate', 'IRAC-21A', 'EC', 'FOLIAR', 0.5, 'ml', NULL, NULL, 'ml', '100ml, 250ml, 500ml', 'FLEXIBLE', 'NRCP miticide rate: 0.4–0.5 ml/L (80–100 ml/drum). Do not overdose EC in hot weather.', 14, FALSE, TRUE, FALSE, FALSE, 0, 0, 0, 0, 0, 0),
('INS_SPIROMESIFEN', 'Spiromesifen 22.9% SC', 'ಸ್ಪೈರೋಮೆಸಿಫೆನ್ 22.9% SC (ನುಸಿ ನಾಶಕ)', 'INSECTICIDE', 'Spiromesifen 22.9% SC', 'Oberon (Bayer)', 'IRAC-23', 'SC', 'FOLIAR', 0.5, 'ml', NULL, NULL, 'ml', '100ml, 240ml', 'FLEXIBLE', 'NRCP miticide rate: 0.5 ml/L (100 ml/drum).', 14, FALSE, TRUE, FALSE, FALSE, 0, 0, 0, 0, 0, 0),
('FUN_AZOXY_TEBU', 'Azoxystrobin 11% + Tebuconazole 18.3% SC', 'ಅಜಾಕ್ಸಿಸ್ಟ್ರೋಬಿನ್ 11% + ಟೆಬುಕೊನಜೋಲ್ 18.3% SC', 'FUNGICIDE', 'Azoxystrobin 11% + Tebuconazole 18.3% SC', 'Custodia Prime, Custodia (Adama), Spectrum', 'FRAC-11+3', 'SC', 'FOLIAR', 1.0, 'ml', NULL, NULL, 'ml', '250ml, 500ml, 1L', 'FLEXIBLE', NULL, 15, FALSE, TRUE, FALSE, FALSE, 0, 0, 0, 0, 0, 0),
('FUN_FLUXA_PYRA', 'Fluxapyroxad 167 + Pyraclostrobin 333 g/L SC', 'ಫ್ಲುಕ್ಸಾಪೈರಾಕ್ಸಾಡ್ + ಪೈರಾಕ್ಲೋಸ್ಟ್ರೋಬಿನ್ SC', 'FUNGICIDE', 'Fluxapyroxad + Pyraclostrobin SC', 'Merivon, Priaxor (BASF)', 'FRAC-7+11', 'SC', 'FOLIAR', 0.6, 'ml', NULL, NULL, 'ml', '100ml, 250ml', 'FLEXIBLE', NULL, 14, FALSE, TRUE, FALSE, FALSE, 0, 0, 0, 0, 0, 0),
('FUN_FLUOPYRAM_TEBU', 'Fluopyram 17.7% + Tebuconazole 17.7% SC', 'ಫ್ಲುವೋಪೈರಾಮ್ + ಟೆಬುಕೊನಜೋಲ್ SC', 'FUNGICIDE', 'Fluopyram + Tebuconazole SC', 'Luna Experience (Bayer)', 'FRAC-7+3', 'SC', 'FOLIAR', 0.8, 'ml', NULL, NULL, 'ml', '100ml, 250ml, 500ml', 'FLEXIBLE', NULL, 14, FALSE, TRUE, FALSE, FALSE, 0, 0, 0, 0, 0, 0),
('FUN_DIFENOCONAZOLE', 'Difenoconazole 25% EC', 'ಡೈಫೆನೊಕೊನಜೋಲ್ 25% EC', 'FUNGICIDE', 'Difenoconazole 25% EC', 'Score (Syngenta)', 'FRAC-3', 'EC', 'FOLIAR', 0.5, 'ml', NULL, NULL, 'ml', '100ml, 250ml, 500ml', 'FLEXIBLE', NULL, 14, FALSE, TRUE, FALSE, FALSE, 0, 0, 0, 0, 0, 0),
('FUN_CABRIO_TOP', 'Cabrio Top (Metiram 55% + Pyraclostrobin 5% WG)', 'ಮೆತಿರಾಮ್ 55% + ಪೈರಾಕ್ಲೋಸ್ಟ್ರೋಬಿನ್ 5% WG', 'FUNGICIDE', 'Metiram 55% + Pyraclostrobin 5% WG', 'Cabrio Top (BASF)', 'FRAC-M03+11', 'WG', 'FOLIAR', 3.0, 'g', NULL, NULL, 'g', '500g, 1kg', 'FLEXIBLE', 'NRCP Table 1 #2 rate: 3.0 g/L (600 g/drum).', 14, FALSE, TRUE, FALSE, FALSE, 0, 0, 0, 0, 0, 0)
ON CONFLICT (id) DO UPDATE SET
    base_dose_per_liter = EXCLUDED.base_dose_per_liter,
    foliar_dose_unit = EXCLUDED.foliar_dose_unit,
    base_dose_per_acre = EXCLUDED.base_dose_per_acre,
    drip_dose_unit = EXCLUDED.drip_dose_unit,
    dealer_warning_en = EXCLUDED.dealer_warning_en,
    phi_days = EXCLUDED.phi_days,
    formulation_type = EXCLUDED.formulation_type,
    n_pct = EXCLUDED.n_pct,
    p_pct = EXCLUDED.p_pct,
    k_pct = EXCLUDED.k_pct,
    ca_pct = EXCLUDED.ca_pct,
    mg_pct = EXCLUDED.mg_pct,
    b_pct = EXCLUDED.b_pct;

INSERT INTO public.substitution_rules (primary_input_id, substitute_input_id, target_purpose, priority_rank, adjustment_note_en) VALUES
('INS_SPINETORAM', 'INS_CYANTRANILIPROLE', 'Thrips & Early Fruit Borer Control', 1, 'Switch dose from 0.8 ml/L (160 ml/drum) to 0.7 ml/L (140 ml/drum).'),
('INS_SPINETORAM', 'INS_SPINOSAD', 'Thrips Knockdown', 2, 'Switch dose from 0.8 ml/L (160 ml/drum) to 0.4–0.5 ml/L (80–100 ml/drum).'),
('BAC_COPPER_HYDROXIDE', 'BAC_COPPER_OXY', 'Bacterial Blight Prophylaxis', 1, 'Switch dose from 1.5 g/L (300 g/drum) to 2.5 g/L (500 g/drum).'),
('FUN_AZOXY_TEBU', 'FUN_FLUOPYRAM_TEBU', 'Anthracnose & Fruit Spot Control', 1, 'Switch dose from 1.0 ml/L (200 ml/drum) to 0.8 ml/L (160 ml/drum).'),
('FUN_AZOXY_TEBU', 'FUN_DIFENOCONAZOLE', 'Fungal Scab & Fruit Spot', 2, 'Switch dose from 1.0 ml/L (200 ml/drum) to 0.5 ml/L (100 ml/drum).'),
('FUN_FLUXA_PYRA', 'FUN_FLUOPYRAM_TEBU', 'Monsoon Fruit Rot Protection', 1, 'Switch dose from 0.6 ml/L (120 ml/drum) to 0.8 ml/L (160 ml/drum).')
ON CONFLICT (primary_input_id, substitute_input_id) DO UPDATE SET
    adjustment_note_en = EXCLUDED.adjustment_note_en;

-- ============================================================================
-- V8: SERVER-SIDE 6-GATE RULE ENGINE RPC & IST DAILY CRON (pg_cron)
-- Fixes: A1, A2 (RLS + search_path), B6 (Idempotency), B7 (DATE + 2 math),
--        B9 (ROW_COUNT sum), B10 (orchard_blocks lookup), B11 (telemetry guard),
--        B12 (Asia/Kolkata date), B13 (block_id + PHI lock + catalog doses),
--        B14 (clean variables & RH >= 72%), C26 (15.2 GDD fallback).
-- ============================================================================
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

CREATE OR REPLACE FUNCTION public.run_daily_orchard_engine(
    target_date DATE DEFAULT (NOW() AT TIME ZONE 'Asia/Kolkata')::DATE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_block_id UUID;
    v_ethrel_date DATE := '2026-08-15';
    v_harvest_date DATE := '2027-02-21'; -- 190 DAD canonical harvest horizon
    v_dad INT;
    v_has_telemetry BOOLEAN := FALSE;
    v_rain_today NUMERIC(5,1) := 0;
    v_cum_gdd NUMERIC(8,2) := 0;
    v_epi_high_days INT := 0;
    v_recent_copper INT := 0;
    v_existing_curative INT := 0;
    v_rows_tmp INT := 0;
    v_shifted_drips INT := 0;
    v_injected_sprays INT := 0;
    v_cop_dose NUMERIC(8,3) := 2.0;
    v_bron_dose NUMERIC(8,3) := 0.5;
    v_cop_phi INT := 7;
    v_days_to_harvest INT;
    v_env TEXT;
BEGIN
    -- 1. Load canonical block metadata from orchard_blocks (Item B10 & B13)
    SELECT id, ethrel_spray_date, COALESCE(expected_harvest_date, ethrel_spray_date + 190)
    INTO v_block_id, v_ethrel_date, v_harvest_date
    FROM public.orchard_blocks
    ORDER BY ethrel_spray_date DESC
    LIMIT 1;

    v_ethrel_date := COALESCE(v_ethrel_date, '2026-08-15'::DATE);
    v_harvest_date := COALESCE(v_harvest_date, v_ethrel_date + 190);
    v_dad := (target_date - v_ethrel_date);
    v_days_to_harvest := (v_harvest_date - (target_date + 1));

    -- 2. Verify whether today's telemetry or manual farm rain log exists yet (Item B11)
    SELECT (
        EXISTS (SELECT 1 FROM public.weather_telemetry_history WHERE log_date = target_date)
        OR EXISTS (SELECT 1 FROM public.farm_rain_logs WHERE log_date = target_date)
    ) INTO v_has_telemetry;

    IF NOT v_has_telemetry THEN
        RETURN jsonb_build_object(
            'status', 'SKIPPED_NO_TELEMETRY',
            'evaluated_date', target_date,
            'dad', v_dad
        );
    END IF;

    -- 3. Merge Automated Telemetry with Priority Manual Farm Rain Override (Gate P0)
    SELECT COALESCE(
        (SELECT rain_mm FROM public.farm_rain_logs WHERE log_date = target_date),
        (SELECT rain_mm FROM public.weather_telemetry_history WHERE log_date = target_date),
        0
    ) INTO v_rain_today;

    -- 4. Compute Cumulative Thermal GDD Since Ethrel Defoliation (Item C26: 15.2 GDD/day fallback)
    SELECT COALESCE(SUM(daily_gdd), GREATEST(0, v_dad) * 15.2)
    INTO v_cum_gdd
    FROM public.weather_telemetry_history
    WHERE log_date BETWEEN v_ethrel_date AND target_date;

    -- 5. Evaluate 72-Hour Epidemiological Microclimate Window (RH >= 72% & Temp 25.0–32.5°C for 3 days)
    SELECT COUNT(*)
    INTO v_epi_high_days
    FROM public.weather_telemetry_history
    WHERE log_date BETWEEN (target_date - 2) AND target_date
      AND humidity_mean_pct >= 72
      AND temp_max_c BETWEEN 25.0 AND 32.5;

    -- 6. Look up Copper Hydroxide & Bronopol PHI / doses from inputs_catalog (Item B13)
    SELECT COALESCE(GREATEST(base_dose_per_liter, 2.0), 2.0), COALESCE(phi_days, 7)
    INTO v_cop_dose, v_cop_phi
    FROM public.inputs_catalog
    WHERE id = 'BAC_COPPER_HYDROXIDE';

    SELECT COALESCE(base_dose_per_liter, 0.5)
    INTO v_bron_dose
    FROM public.inputs_catalog
    WHERE id = 'BAC_BRONOPOL';

    -- Run across both PROD and DEV environments
    FOREACH v_env IN ARRAY ARRAY['PROD', 'DEV'] LOOP

        -- 7. Gate P0 + P4 (Idempotent): Heavy Rain (>= 15 mm) -> Shift Un-Shifted Drip Tasks Forward by +2 Days
        -- Fixes B6 (skips tasks already delayed for RAIN), B7 (uses date + 2 integer math), B9 (accumulates ROW_COUNT)
        IF v_rain_today >= 15.0 THEN
            UPDATE public.daily_task_queue
            SET current_scheduled_date = current_scheduled_date + 2,
                effective_dad = ((current_scheduled_date + 2) - v_ethrel_date),
                status = 'DELAYED',
                delay_reason = 'RAIN',
                updated_by = 'AUTO_CRON_0530',
                updated_at = NOW()
            WHERE env = v_env
              AND status IN ('PENDING', 'DELAYED')
              AND COALESCE(delay_reason, '') <> 'RAIN'
              AND task_type LIKE 'DRIP%'
              AND current_scheduled_date BETWEEN target_date AND (target_date + 3);

            GET DIAGNOSTICS v_rows_tmp = ROW_COUNT;
            v_shifted_drips := v_shifted_drips + v_rows_tmp;
        END IF;

        -- 8. Gate P0 + P1 + P2: Proactive Bactericide Injection on Heavy Rain (>=15mm) OR 72h Epidemiological Trigger
        -- Respects Pre-Harvest PHI Lock (v_days_to_harvest >= v_cop_phi) and 5-day Copper Cooldown
        IF (v_rain_today >= 15.0 OR v_epi_high_days >= 3) AND (v_days_to_harvest >= v_cop_phi) THEN
            SELECT COUNT(*) INTO v_recent_copper
            FROM public.daily_task_queue q
            WHERE q.env = v_env
              AND q.status = 'COMPLETED'
              AND q.current_scheduled_date BETWEEN (target_date - 5) AND target_date
              AND (
                  q.task_type = 'STANDALONE_COPPER'
                  OR EXISTS (
                      SELECT 1
                      FROM jsonb_array_elements(q.resolved_recipe) AS elem
                      JOIN public.inputs_catalog ic ON ic.id = (elem->>'input_id')
                      WHERE ic.is_copper_compound IS TRUE
                  )
              );

            SELECT COUNT(*) INTO v_existing_curative
            FROM public.daily_task_queue
            WHERE env = v_env
              AND status IN ('PENDING', 'DELAYED')
              AND current_scheduled_date BETWEEN target_date AND (target_date + 4)
              AND (task_type = 'STANDALONE_COPPER' OR trigger_source IN ('RAIN_EMERGENCY', 'SCOUTING_CURATIVE'));

            IF v_recent_copper = 0 AND v_existing_curative = 0 THEN
                INSERT INTO public.daily_task_queue (
                    id, block_id, env, originally_scheduled_date, current_scheduled_date, effective_dad,
                    task_type, trigger_source, status, resolved_recipe,
                    custom_title_en, custom_title_kn, updated_by, updated_at
                ) VALUES (
                    gen_random_uuid(),
                    v_block_id,
                    v_env,
                    (target_date + 1),
                    (target_date + 1),
                    v_dad + 1,
                    'STANDALONE_COPPER',
                    CASE WHEN v_rain_today >= 15.0 THEN 'RAIN_EMERGENCY' ELSE 'SCOUTING_CURATIVE' END,
                    'PENDING',
                    jsonb_build_array(
                        jsonb_build_object('input_id', 'BAC_COPPER_HYDROXIDE', 'dose_per_liter', v_cop_dose),
                        jsonb_build_object('input_id', 'BAC_BRONOPOL', 'dose_per_liter', v_bron_dose)
                    ),
                    'Curative Copper Bactericide Spray',
                    'ತುರ್ತು ಕಾಪರ್ ಬ್ಯಾಕ್ಟೀರಿಯಾ ಸಿಂಪಡಣೆ',
                    'AUTO_CRON_0530',
                    NOW()
                );
                v_injected_sprays := v_injected_sprays + 1;
            END IF;
        END IF;

    END LOOP;

    RETURN jsonb_build_object(
        'status', 'OK',
        'evaluated_date', target_date,
        'dad', v_dad,
        'cumulative_gdd', v_cum_gdd,
        'rain_today_mm', v_rain_today,
        'epi_high_days_72h', v_epi_high_days,
        'shifted_drips', v_shifted_drips,
        'injected_sprays', v_injected_sprays
    );
END;
$$;

-- Harden RPC permissions (Item A2): revoke PUBLIC default, grant to authenticated/service_role (and anon until Supabase Auth UI is enabled)
REVOKE ALL ON FUNCTION public.run_daily_orchard_engine(DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.run_daily_orchard_engine(DATE) TO authenticated, service_role, anon;
-- NOTE: Once you enable a shared family login via Supabase Auth in index.html, run:
-- REVOKE EXECUTE ON FUNCTION public.run_daily_orchard_engine(DATE) FROM anon;

-- Enable Row-Level Security (RLS) on all tables (Item A1)
ALTER TABLE public.orchard_blocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inputs_catalog ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shed_leftovers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.substitution_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.baseline_schedule_template ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.daily_task_queue ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.weather_telemetry_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.farm_rain_logs ENABLE ROW LEVEL SECURITY;

-- Idempotent RLS Policies (Change `TO authenticated, anon` -> `TO authenticated` once shared login is enabled)
DO $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'orchard_blocks', 'inputs_catalog', 'shed_leftovers', 'substitution_rules',
        'baseline_schedule_template', 'daily_task_queue', 'weather_telemetry_history', 'farm_rain_logs'
    ] LOOP
        EXECUTE format('DROP POLICY IF EXISTS orchard_access_policy ON public.%I;', t);
        EXECUTE format(
            'CREATE POLICY orchard_access_policy ON public.%I FOR ALL TO authenticated, anon USING (true) WITH CHECK (true);',
            t
        );
    END LOOP;
END $$;

-- Schedule automatic execution at 08:30 AM IST (03:00 UTC) after morning telemetry is available
SELECT cron.schedule(
    'hosahalli-daily-0530-ist-engine',
    '0 3 * * *',
    $$SELECT public.run_daily_orchard_engine((NOW() AT TIME ZONE 'Asia/Kolkata')::DATE);$$
);
