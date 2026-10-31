-- ============================================================================
-- HOSAHALLI POMEGRANATE DYNAMIC TRACKER - POSTGRESQL / SUPABASE SCHEMA
-- Coordinates: 14.661830, 76.454375 | 3 Acres | 1,500 Plants (10x8 ft)
-- ============================================================================

-- 1. ORCHARD CONFIGURATION
CREATE TABLE orchard_blocks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL DEFAULT 'Hosahalli Pomegranate Orchard',
    gps_lat NUMERIC(9,6) NOT NULL DEFAULT 14.661830,
    gps_lon NUMERIC(9,6) NOT NULL DEFAULT 76.454375,
    area_acres NUMERIC(5,2) NOT NULL DEFAULT 3.00,
    plant_count INT NOT NULL DEFAULT 1500,
    spacing_ft TEXT DEFAULT '10x8',
    ethrel_spray_date DATE NOT NULL DEFAULT '2026-08-15',
    expected_harvest_date DATE NOT NULL DEFAULT '2027-02-25',
    default_drums_per_spray NUMERIC(4,1) NOT NULL DEFAULT 7.0, -- 7 x 200L = 1,400L for 3 acres
    manual_stage_override TEXT CHECK (manual_stage_override IN ('LEMON', 'GUAVA', 'COLOR_INIT', 'HARVEST_READY'))
);

-- Insert your exact Hosahalli block
INSERT INTO orchard_blocks (name, gps_lat, gps_lon, area_acres, plant_count, ethrel_spray_date)
VALUES ('Hosahalli Pomegranate Block (3 Acres)', 14.661830, 76.454375, 3.00, 1500, '2026-08-15');

-- 2. MASTER INPUTS CATALOG (With Store Criticality & Dealer Warnings)
CREATE TABLE inputs_catalog (
    id TEXT PRIMARY KEY,
    name_en TEXT NOT NULL,
    name_kn TEXT NOT NULL,
    category TEXT NOT NULL CHECK (category IN ('FERTIGATION', 'FUNGICIDE', 'INSECTICIDE', 'BACTERICIDE', 'BIOSTIMULANT', 'ADJUVANT')),
    active_ingredient TEXT NOT NULL,
    popular_brands TEXT, -- Helps identify quickly at the local agro store
    irac_frac_group TEXT,
    application_method TEXT NOT NULL CHECK (application_method IN ('DRIP', 'FOLIAR', 'BOTH')),
    base_dose_per_liter NUMERIC(8,3), -- ml or g per Liter of water
    base_dose_per_acre NUMERIC(8,3),  -- kg or g per Acre
    unit TEXT NOT NULL CHECK (unit IN ('ml', 'g', 'kg', 'L')),
    standard_pack_sizes TEXT, -- e.g., '100ml, 250ml, 500ml' or '25kg Bag'
    procurement_criticality TEXT NOT NULL DEFAULT 'FLEXIBLE' 
        CHECK (procurement_criticality IN ('FLEXIBLE', 'CRITICAL_MUST_SOURCE')),
    dealer_warning_en TEXT, -- Warning against bad substitutes pushed by stores
    phi_days INT NOT NULL DEFAULT 0,
    is_copper_compound BOOLEAN DEFAULT FALSE,
    incompatible_with_copper BOOLEAN DEFAULT FALSE,
    incompatible_with_calcium BOOLEAN DEFAULT FALSE,
    contains_nitrogen BOOLEAN DEFAULT FALSE
);

-- 3. SHED LEFTOVER BALANCE (Tracks opened bottles/bags left over from previous purchases)
CREATE TABLE shed_leftovers (
    input_id TEXT PRIMARY KEY REFERENCES inputs_catalog(id),
    leftover_qty NUMERIC(10,2) NOT NULL DEFAULT 0, -- In base unit (ml, g, or kg)
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 4. STORE COUNTER SUBSTITUTION MATRIX
CREATE TABLE substitution_rules (
    id SERIAL PRIMARY KEY,
    primary_input_id TEXT REFERENCES inputs_catalog(id),
    substitute_input_id TEXT REFERENCES inputs_catalog(id),
    target_purpose TEXT NOT NULL,
    priority_rank INT NOT NULL DEFAULT 1, -- 1 = Best store alternative, 2 = Backup alternative
    adjustment_note_en TEXT
);

-- 5. BASELINE 21-WEEK SCHEDULE TEMPLATE
CREATE TABLE baseline_schedule_template (
    id SERIAL PRIMARY KEY,
    week_number INT NOT NULL,
    dad_start INT NOT NULL,
    dad_end INT NOT NULL,
    day_of_week INT NOT NULL, -- 1=Mon, 3=Wed(Spray), 4=Thu, 6=Sat
    task_type TEXT NOT NULL CHECK (task_type IN ('DRIP_MON_THU', 'DRIP_SAT', 'FOLIAR_SPRAY', 'STANDALONE_COPPER')),
    stage_name TEXT NOT NULL,
    target_description TEXT NOT NULL,
    recipe_items JSONB NOT NULL
);

-- 6. DYNAMIC DAILY TASK QUEUE & SHOPPING TRACKER
CREATE TABLE daily_task_queue (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    block_id UUID REFERENCES orchard_blocks(id),
    template_id INT REFERENCES baseline_schedule_template(id),
    originally_scheduled_date DATE NOT NULL,
    current_scheduled_date DATE NOT NULL,
    effective_dad INT NOT NULL,
    task_type TEXT NOT NULL,
    trigger_source TEXT NOT NULL DEFAULT 'BASELINE' 
        CHECK (trigger_source IN ('BASELINE', 'RAIN_EMERGENCY', 'EL_NINO_COLOR_BOOST', 'HEAT_CRACK_SHIELD', 'SCOUTING_CURATIVE')),
    status TEXT NOT NULL DEFAULT 'PENDING' 
        CHECK (status IN ('PENDING', 'SHOPPING_NEEDED', 'HOLD_WEATHER', 'COMPLETED', 'DELAYED', 'SKIPPED')),
    resolved_recipe JSONB NOT NULL, -- Includes net_to_buy after deducting shed_leftovers
    delay_reason TEXT CHECK (delay_reason IN ('RAIN', 'NO_POWER', 'NO_LABOR', 'SOURCING_FROM_OTHER_TOWN')),
    executed_at TIMESTAMPTZ,
    notes TEXT
);

-- 7. DAILY WEATHER & FIELD SCOUTING LOGS
CREATE TABLE weather_and_scouting_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    block_id UUID REFERENCES orchard_blocks(id),
    log_date DATE NOT NULL DEFAULT CURRENT_DATE,
    rain_24h_mm NUMERIC(5,1) DEFAULT 0,
    rain_forecast_4h_prob INT DEFAULT 0,
    wind_speed_kmh NUMERIC(4,1) DEFAULT 0,
    temp_max_c NUMERIC(4,1),
    temp_min_c NUMERIC(4,1),
    humidity_pct INT,
    scouting_symptom TEXT CHECK (scouting_symptom IN ('BLIGHT_SPOT', 'THRIPS_SCAR', 'FRUIT_BORER', 'MEALYBUG', 'FRUIT_ROT', 'CRACKING')),
    symptom_severity TEXT CHECK (symptom_severity IN ('LOW', 'MEDIUM', 'HIGH')),
    UNIQUE(block_id, log_date)
);

-- ============================================================================
-- SEED CORE INPUTS & STORE SUBSTITUTION RULES
-- ============================================================================
INSERT INTO inputs_catalog (
    id, name_en, name_kn, category, active_ingredient, popular_brands, irac_frac_group,
    application_method, base_dose_per_liter, base_dose_per_acre, unit, standard_pack_sizes,
    procurement_criticality, dealer_warning_en, phi_days, is_copper_compound, incompatible_with_copper, incompatible_with_calcium, contains_nitrogen
) VALUES
-- Water Soluble Fertilizers
('WSF_00_52_34', '00:52:34 (MKP)', '00:52:34 (ಎಂ.ಕೆ.ಪಿ)', 'FERTIGATION', 'Mono Potassium Phosphate', 'Haifa, Coromandel, IFFCO, Mahadhan', NULL, 'BOTH', 4.0, 3.5, 'kg', '1kg, 25kg Bag', 'CRITICAL_MUST_SOURCE', 'Do NOT substitute with DAP or 19:19:19 during fruit sizing/color stages (excess Nitrogen ruins rind quality).', 0, FALSE, FALSE, TRUE, FALSE),
('WSF_00_00_50', '00:00:50 (SOP)', '00:00:50 (ಎಸ್.ಒ.ಪಿ - ಸಲ್ಫೇಟ್ ಆಫ್ ಪೊಟ್ಯಾಷ್)', 'FERTIGATION', 'Potassium Sulphate (50% K2O)', 'SQM, Haifa, Mahadhan, IFFCO', NULL, 'BOTH', 5.0, 5.0, 'kg', '1kg, 25kg Bag', 'CRITICAL_MUST_SOURCE', 'CRITICAL: Never accept Muriate of Potash (MOP / Red Potash) or 13:00:45 after 140 DAD. Chloride burns roots and Nitrate keeps skin green.', 0, FALSE, FALSE, TRUE, FALSE),
('WSF_13_00_45', '13:00:45 (Potassium Nitrate)', '13:00:45 (ಪೊಟ್ಯಾಸಿಯಮ್ ನೈಟ್ರೇಟ್)', 'FERTIGATION', 'Potassium Nitrate', 'Haifa Multi-K, Coromandel, Mahadhan', NULL, 'BOTH', 4.0, 3.0, 'kg', '1kg, 25kg Bag', 'FLEXIBLE', 'Safe to use only before 140 DAD. After Jan 2, switch strictly to 00:00:50.', 0, FALSE, FALSE, FALSE, TRUE),
('WSF_CALCIUM_NITRATE', 'Calcium Nitrate (Water Soluble)', 'ಕ್ಯಾಲ್ಸಿಯಂ ನೈಟ್ರೇಟ್', 'FERTIGATION', '15.5% N + 18.8% Ca', 'YaraLiva Tropicote/Calcinit, Mahadhan', NULL, 'BOTH', 3.0, 3.5, 'kg', '1kg, 10kg, 25kg Bag', 'CRITICAL_MUST_SOURCE', 'Must run alone in drip tank. Never mix with 00:52:34, 00:00:50, or MgSO4.', 0, FALSE, FALSE, FALSE, TRUE),
('WSF_MGSO4', 'Magnesium Sulphate (MgSO4)', 'ಮೆಗ್ನೀಸಿಯಮ್ ಸಲ್ಫೇಟ್', 'FERTIGATION', 'Magnesium Sulphate Heptahydrate', 'Any Standard Grade', NULL, 'BOTH', 2.0, 2.5, 'kg', '1kg, 25kg Bag', 'FLEXIBLE', NULL, 0, FALSE, FALSE, TRUE, FALSE),

-- Bactericides (Critical for Pomegranate Blight)
('BAC_COPPER_HYDROXIDE', 'Copper Hydroxide 53.8% DF', 'ಕಾಪರ್ ಹೈಡ್ರಾಕ್ಸೈಡ್', 'BACTERICIDE', 'Copper Hydroxide 53.8% DF', 'Kocide 2000, Hidrokop', 'FRAC-M01', 'FOLIAR', 1.5, NULL, 'g', '250g, 500g', 'FLEXIBLE', 'If Kocide 2000 is unavailable, use Copper Oxychloride 50% WP at 2.0 g/L. Spray standalone.', 7, TRUE, FALSE, FALSE, FALSE),
('BAC_COPPER_OXY', 'Copper Oxychloride 50% WP', 'ಕಾಪರ್ ಆಕ್ಸಿಕ್ಲೋರೈಡ್ (COC)', 'BACTERICIDE', 'Copper Oxychloride 50% WP', 'Blitox, Blue Copper, Trucop', 'FRAC-M01', 'FOLIAR', 2.0, NULL, 'g', '500g, 1kg', 'FLEXIBLE', 'Spray standalone with Bronopol. Do not mix with amino acids or insecticides.', 7, TRUE, FALSE, FALSE, FALSE),
('BAC_BRONOPOL', 'Bronopol 95% (Bactericide)', 'ಬ್ರೊನೊಪಾಲ್ (ಬ್ಯಾಕ್ಟೀರಿಯಾ ನಾಶಕ)', 'BACTERICIDE', '2-Bromo-2-nitropropane-1,3-diol', 'Bactrinashak, Bronocil, Balwan', 'BACTERICIDE', 'FOLIAR', 0.5, NULL, 'g', '50g, 100g', 'CRITICAL_MUST_SOURCE', 'Essential partner with Copper for Bacterial Blight. If unavailable, ask for Kasugamycin 3% SL (1.5 ml/L).', 7, FALSE, FALSE, FALSE, FALSE),

-- Insecticides (With Ranked Substitutes for Store Counter)
('INS_SPINETORAM', 'Spinetoram 11.7% SC', 'ಸ್ಪೈನೆಟೊರಾಮ್', 'INSECTICIDE', 'Spinetoram 11.7% SC', 'Delegate (Corteva), Largo (Dhanuka)', 'IRAC-5', 'FOLIAR', 0.8, NULL, 'ml', '100ml, 180ml, 500ml', 'FLEXIBLE', 'Top choice for Thrips & Fruit Borer without triggering mite flare-ups. Do not substitute with cheap synthetic pyrethroids.', 14, FALSE, TRUE, FALSE, FALSE),
('INS_CYANTRANILIPROLE', 'Cyantraniliprole 10.26% OD', 'ಸೈಯಾಂಟ್ರಾನಿಲಿಪ್ರೋಲ್', 'INSECTICIDE', 'Cyantraniliprole 10.26% OD', 'Benevia (FMC)', 'IRAC-28', 'FOLIAR', 0.7, NULL, 'ml', '90ml, 180ml, 450ml', 'FLEXIBLE', 'Excellent substitute if Spinetoram is out of stock; controls both Thrips and Fruit Borer.', 14, FALSE, TRUE, FALSE, FALSE),
('INS_SPINOSAD', 'Spinosad 45% SC', 'ಸ್ಪೈನೋಸಾಡ್', 'INSECTICIDE', 'Spinosad 45% SC', 'Tracer (Corteva), Conserve', 'IRAC-5', 'FOLIAR', 0.3, NULL, 'ml', '75ml, 150ml', 'FLEXIBLE', 'Safe short-PHI thrips alternative, especially in January/February.', 7, FALSE, TRUE, FALSE, FALSE),
('INS_CHLORANTRANILIPROLE', 'Chlorantraniliprole 18.5% SC', 'ಕ್ಲೋರಾಂಟ್ರಾನಿಲಿಪ್ರೋಲ್', 'INSECTICIDE', 'Chlorantraniliprole 18.5% SC', 'Coragen (FMC), Cover', 'IRAC-28', 'FOLIAR', 0.3, NULL, 'ml', '60ml, 150ml', 'FLEXIBLE', 'Targets Fruit Borer (Deudorix) caterpillars only; does not control Thrips.', 14, FALSE, TRUE, FALSE, FALSE),

-- Fungicides (Anthracnose, Cercospora, Fruit Rot)
('FUN_AZOXY_TEBU', 'Azoxystrobin 11% + Tebuconazole 18.3% SC', 'ಅಜಾಕ್ಸಿಸ್ಟ್ರೋಬಿನ್ + ಟೆಬುಕೊನಜೋಲ್', 'FUNGICIDE', 'Azoxystrobin + Tebuconazole', 'Custodia (Adama), Spectrum', 'FRAC-11+3', 'FOLIAR', 1.0, NULL, 'ml', '250ml, 500ml, 1L', 'FLEXIBLE', NULL, 15, FALSE, TRUE, FALSE, FALSE),
('FUN_FLUXA_PYRA', 'Fluxapyroxad 167 + Pyraclostrobin 333 g/L SC', 'ಫ್ಲಕ್ಸಾಪೈರಾಕ್ಸಾಡ್ + ಪೈರಾಕ್ಲೋಸ್ಟ್ರೋಬಿನ್', 'FUNGICIDE', 'Fluxapyroxad + Pyraclostrobin', 'Merivon, Priaxor (BASF)', 'FRAC-7+11', 'FOLIAR', 0.6, NULL, 'ml', '100ml, 250ml', 'FLEXIBLE', NULL, 14, FALSE, TRUE, FALSE, FALSE),
('FUN_FLUOPYRAM_TEBU', 'Fluopyram 17.7% + Tebuconazole 17.7% SC', 'ಫ್ಲುವೋಪೈರಾಮ್ + ಟೆಬುಕೊನಜೋಲ್', 'FUNGICIDE', 'Fluopyram + Tebuconazole', 'Luna Experience (Bayer)', 'FRAC-7+3', 'FOLIAR', 0.8, NULL, 'ml', '100ml, 250ml, 500ml', 'FLEXIBLE', NULL, 14, FALSE, TRUE, FALSE, FALSE),
('FUN_DIFENOCONAZOLE', 'Difenoconazole 25% EC', 'ಡೈಫೆನೊಕೊನಜೋಲ್', 'FUNGICIDE', 'Difenoconazole 25% EC', 'Score (Syngenta)', 'FRAC-3', 'FOLIAR', 0.5, NULL, 'ml', '100ml, 250ml, 500ml', 'FLEXIBLE', NULL, 14, FALSE, TRUE, FALSE, FALSE);

-- Seed Store Substitution Matrix
INSERT INTO substitution_rules (primary_input_id, substitute_input_id, target_purpose, priority_rank, adjustment_note_en) VALUES
('INS_SPINETORAM', 'INS_CYANTRANILIPROLE', 'Thrips & Early Fruit Borer Control', 1, 'Switch dose from 0.8 ml/L (160 ml/drum) to 0.7 ml/L (140 ml/drum).'),
('INS_SPINETORAM', 'INS_SPINOSAD', 'Thrips Knockdown', 2, 'Switch dose from 0.8 ml/L (160 ml/drum) to 0.3 ml/L (60 ml/drum).'),
('BAC_COPPER_HYDROXIDE', 'BAC_COPPER_OXY', 'Bacterial Blight Prophylaxis', 1, 'Switch dose from 1.5 g/L (300 g/drum) to 2.0 g/L (400 g/drum).'),
('FUN_AZOXY_TEBU', 'FUN_FLUOPYRAM_TEBU', 'Anthracnose & Fruit Spot Control', 1, 'Switch dose from 1.0 ml/L (200 ml/drum) to 0.8 ml/L (160 ml/drum).'),
('FUN_AZOXY_TEBU', 'FUN_DIFENOCONAZOLE', 'Fungal Scab & Fruit Spot', 2, 'Switch dose from 1.0 ml/L (200 ml/drum) to 0.5 ml/L (100 ml/drum).'),
('FUN_FLUXA_PYRA', 'FUN_FLUOPYRAM_TEBU', 'Monsoon Fruit Rot Protection', 1, 'Switch dose from 0.6 ml/L (120 ml/drum) to 0.8 ml/L (160 ml/drum).');
/* =========================================================================
   V6–V7 SCHEMA EXTENSIONS (ALREADY APPLIED IN SUPABASE — SYNCED FOR GITHUB)
   ========================================================================= */
ALTER TABLE inputs_catalog ADD COLUMN IF NOT EXISTS formulation_type TEXT DEFAULT 'SC';
ALTER TABLE inputs_catalog ADD COLUMN IF NOT EXISTS n_pct NUMERIC(5,2) DEFAULT 0;
ALTER TABLE inputs_catalog ADD COLUMN IF NOT EXISTS p_pct NUMERIC(5,2) DEFAULT 0;
ALTER TABLE inputs_catalog ADD COLUMN IF NOT EXISTS k_pct NUMERIC(5,2) DEFAULT 0;
ALTER TABLE inputs_catalog ADD COLUMN IF NOT EXISTS ca_pct NUMERIC(5,2) DEFAULT 0;
ALTER TABLE inputs_catalog ADD COLUMN IF NOT EXISTS mg_pct NUMERIC(5,2) DEFAULT 0;

ALTER TABLE daily_task_queue ADD COLUMN IF NOT EXISTS cost_rs NUMERIC(10,2) DEFAULT 0;
ALTER TABLE daily_task_queue ADD COLUMN IF NOT EXISTS version_int INT NOT NULL DEFAULT 1;
ALTER TABLE daily_task_queue ADD COLUMN IF NOT EXISTS custom_title_en TEXT;
ALTER TABLE daily_task_queue ADD COLUMN IF NOT EXISTS custom_title_kn TEXT;

CREATE TABLE IF NOT EXISTS weather_telemetry_history (
    log_date DATE PRIMARY KEY,
    temp_max_c NUMERIC(4,1) NOT NULL DEFAULT 30.5,
    temp_min_c NUMERIC(4,1) NOT NULL DEFAULT 18.5,
    humidity_mean_pct INT NOT NULL DEFAULT 60,
    rain_mm NUMERIC(5,1) NOT NULL DEFAULT 0,
    daily_gdd NUMERIC(5,2) NOT NULL DEFAULT 14.5,
    disease_risk_score INT NOT NULL DEFAULT 25,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS farm_rain_logs (
    log_date DATE PRIMARY KEY,
    rain_mm NUMERIC(5,1) NOT NULL DEFAULT 0,
    rain_label TEXT,
    logged_by TEXT DEFAULT 'Vishwanath',
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================================
-- V8: SERVER-SIDE 6-GATE RULE ENGINE RPC & 05:30 AM IST DAILY CRON (pg_cron)
-- ============================================================================
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

CREATE OR REPLACE FUNCTION public.run_daily_orchard_engine(target_date DATE DEFAULT CURRENT_DATE)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_ethrel_date DATE := '2026-08-15';
    v_dad INT := (target_date - v_ethrel_date);
    v_rain_today NUMERIC(5,1) := 0;
    v_rain_72h NUMERIC(5,1) := 0;
    v_rh_72h NUMERIC(5,1) := 60;
    v_tmax_72h NUMERIC(4,1) := 30.0;
    v_tmin_today NUMERIC(4,1) := 18.5;
    v_cum_gdd NUMERIC(8,2) := 0;
    v_epi_high_days INT := 0;
    v_recent_copper INT := 0;
    v_existing_curative INT := 0;
    v_shifted_drips INT := 0;
    v_injected_sprays INT := 0;
    v_env TEXT;
BEGIN
    -- 1. Merge Automated Telemetry with Priority Manual Farm Rain Override (Gate P0)
    SELECT COALESCE(
        (SELECT rain_mm FROM farm_rain_logs WHERE log_date = target_date),
        (SELECT rain_mm FROM weather_telemetry_history WHERE log_date = target_date),
        0
    ) INTO v_rain_today;

    SELECT
        COALESCE(SUM(rain_mm), 0),
        COALESCE(AVG(humidity_mean_pct), 60),
        COALESCE(AVG(temp_max_c), 30.0)
    INTO v_rain_72h, v_rh_72h, v_tmax_72h
    FROM weather_telemetry_history
    WHERE log_date BETWEEN (target_date - INTERVAL '2 days')::DATE AND target_date;

    SELECT COALESCE(temp_min_c, 18.5)
    INTO v_tmin_today
    FROM weather_telemetry_history
    WHERE log_date = target_date;

    -- 2. Compute Cumulative Thermal GDD Since Ethrel Defoliation (2026-08-15)
    SELECT COALESCE(SUM(daily_gdd), v_dad * 15.8)
    INTO v_cum_gdd
    FROM weather_telemetry_history
    WHERE log_date BETWEEN v_ethrel_date AND target_date;

    -- 3. Evaluate 72-Hour Epidemiological Microclimate Window (RH > 80% & Temp 25°C–32°C for 3 days)
    SELECT COUNT(*)
    INTO v_epi_high_days
    FROM weather_telemetry_history
    WHERE log_date BETWEEN (target_date - INTERVAL '2 days')::DATE AND target_date
      AND humidity_mean_pct >= 80
      AND temp_max_c BETWEEN 25.0 AND 32.5;

    -- Run across both PROD and DEV environments
    FOREACH v_env IN ARRAY ARRAY['PROD', 'DEV'] LOOP

        -- 4. Gate P0 + P4: Heavy Rain (>= 15 mm) -> Pause & Shift Pending Drip Tasks Forward by +2 Days
        IF v_rain_today >= 15.0 THEN
            UPDATE daily_task_queue
            SET current_scheduled_date = current_scheduled_date + INTERVAL '2 days',
                effective_dad = (current_scheduled_date + INTERVAL '2 days' - v_ethrel_date),
                status = 'DELAYED',
                delay_reason = 'RAIN',
                updated_by = 'AUTO_CRON_0530',
                updated_at = NOW()
            WHERE env = v_env
              AND status IN ('PENDING', 'DELAYED')
              AND task_type LIKE 'DRIP%'
              AND current_scheduled_date BETWEEN target_date AND (target_date + INTERVAL '3 days')::DATE;

            GET DIAGNOSTICS v_shifted_drips = ROW_COUNT;
        END IF;

        -- 5. Gate P0 + P2 + P3: Proactive Bactericide Injection on Heavy Rain (>=15mm) OR 72h Epidemiological Trigger
        IF (v_rain_today >= 15.0 OR v_epi_high_days >= 3) THEN
            -- Respect Gate P2 5-day Copper Cooldown
            SELECT COUNT(*) INTO v_recent_copper
            FROM daily_task_queue
            WHERE env = v_env
              AND status = 'COMPLETED'
              AND current_scheduled_date BETWEEN (target_date - INTERVAL '5 days')::DATE AND target_date
              AND (task_type = 'STANDALONE_COPPER' OR resolved_recipe::TEXT ILIKE '%COPPER%');

            SELECT COUNT(*) INTO v_existing_curative
            FROM daily_task_queue
            WHERE env = v_env
              AND status IN ('PENDING', 'DELAYED')
              AND current_scheduled_date BETWEEN target_date AND (target_date + INTERVAL '4 days')::DATE
              AND (task_type = 'STANDALONE_COPPER' OR trigger_source IN ('RAIN_EMERGENCY', 'SCOUTING_CURATIVE'));

            IF v_recent_copper = 0 AND v_existing_curative = 0 THEN
                INSERT INTO daily_task_queue (
                    id, env, originally_scheduled_date, current_scheduled_date, effective_dad,
                    task_type, trigger_source, status, resolved_recipe,
                    custom_title_en, custom_title_kn, updated_by, updated_at
                ) VALUES (
                    gen_random_uuid(),
                    v_env,
                    (target_date + INTERVAL '1 day')::DATE,
                    (target_date + INTERVAL '1 day')::DATE,
                    v_dad + 1,
                    'STANDALONE_COPPER',
                    CASE WHEN v_rain_today >= 15.0 THEN 'RAIN_EMERGENCY' ELSE 'SCOUTING_CURATIVE' END,
                    'PENDING',
                    '[{"input_id":"BAC_COPPER_HYDROXIDE","dose_per_liter":1.5},{"input_id":"BAC_BRONOPOL","dose_per_liter":0.5}]'::JSONB,
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

-- Schedule automatic execution every day at 05:30 AM IST (00:00 UTC)
SELECT cron.schedule(
    'hosahalli-daily-0530-ist-engine',
    '0 0 * * *',
    $$SELECT public.run_daily_orchard_engine(CURRENT_DATE);$$
);
