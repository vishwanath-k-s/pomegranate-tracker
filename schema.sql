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
