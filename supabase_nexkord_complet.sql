-- ══════════════════════════════════════════════════════════════════
-- NEXKORD — Schéma Supabase complet
-- JOJ Dakar 2026 · Version 4.0
-- Instructions : Coller dans Supabase > SQL Editor > Run
-- ══════════════════════════════════════════════════════════════════

-- Extensions requises
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "moddatetime";

-- ──────────────────────────────────────────────
-- 1. PROFILS UTILISATEURS
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.profiles (
  id            UUID REFERENCES auth.users ON DELETE CASCADE PRIMARY KEY,
  nom           TEXT NOT NULL DEFAULT 'Utilisateur',
  telephone     TEXT,
  role          TEXT NOT NULL DEFAULT 'VIEWER'
                CHECK (role IN ('SUPER_ADMIN','ADMIN','OPERATOR','VIEWER')),
  zone          TEXT DEFAULT 'Dakar',
  axe           TEXT,
  certif        TEXT DEFAULT 'PSC1',
  actif         BOOLEAN DEFAULT TRUE,
  signalements  INT DEFAULT 0,
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  updated_at    TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "profiles_own" ON profiles
  FOR ALL USING (auth.uid() = id);

CREATE POLICY "profiles_admin_read" ON profiles
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('ADMIN','SUPER_ADMIN'))
  );

CREATE TRIGGER profiles_updated_at
  BEFORE UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION moddatetime(updated_at);

-- Créer le profil automatiquement après inscription
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (id, nom, role)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'nom', split_part(NEW.email, '@', 1)),
    COALESCE(NEW.raw_user_meta_data->>'role', 'VIEWER')
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();

-- ──────────────────────────────────────────────
-- 2. SIGNAUX SAP mINFOSANTÉ
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.sap_signals (
  id            UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  code          TEXT GENERATED ALWAYS AS ('SIG-' || UPPER(SUBSTR(id::text, 1, 6))) STORED,
  type          TEXT NOT NULL DEFAULT 'CHOC_GRAVE',
  axe           TEXT NOT NULL,
  lieu_detail   TEXT,
  victimes      INT DEFAULT 0,
  gravite       TEXT NOT NULL DEFAULT 'urgent'
                CHECK (gravite IN ('critique','urgent','modere','leger')),
  statut        TEXT DEFAULT 'actif'
                CHECK (statut IN ('actif','pris_en_charge','clos')),
  lat           FLOAT,
  lon           FLOAT,
  precision_m   INT,
  photo_url     TEXT,
  transcription TEXT,
  region        TEXT DEFAULT 'Dakar',
  signaleur_id  UUID REFERENCES profiles(id) ON DELETE SET NULL,
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  updated_at    TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX ON sap_signals(statut, created_at DESC);
CREATE INDEX ON sap_signals(gravite, created_at DESC);
CREATE INDEX ON sap_signals(region, created_at DESC);

ALTER TABLE sap_signals ENABLE ROW LEVEL SECURITY;

CREATE POLICY "sap_operator_own" ON sap_signals
  FOR ALL USING (signaleur_id = auth.uid());

CREATE POLICY "sap_admin_all" ON sap_signals
  FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('ADMIN','SUPER_ADMIN'))
  );

CREATE TRIGGER sap_signals_updated_at
  BEFORE UPDATE ON sap_signals
  FOR EACH ROW EXECUTE FUNCTION moddatetime(updated_at);

ALTER PUBLICATION supabase_realtime ADD TABLE sap_signals;

-- ──────────────────────────────────────────────
-- 3. INCIDENTS COUS
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.cous_incidents (
  id            UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  code          TEXT GENERATED ALWAYS AS ('COUS-' || UPPER(SUBSTR(id::text, 1, 6))) STORED,
  type          TEXT NOT NULL,
  lieu          TEXT NOT NULL,
  gravite       TEXT NOT NULL DEFAULT 'urgent'
                CHECK (gravite IN ('critique','urgent','modere')),
  statut        TEXT DEFAULT 'en_cours'
                CHECK (statut IN ('en_cours','en_surveillance','ferme')),
  equipes       TEXT[] DEFAULT '{}',
  declarant_id  UUID REFERENCES profiles(id) ON DELETE SET NULL,
  signal_id     UUID REFERENCES sap_signals(id) ON DELETE SET NULL,
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  updated_at    TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX ON cous_incidents(statut, created_at DESC);
CREATE INDEX ON cous_incidents(gravite, created_at DESC);

ALTER TABLE cous_incidents ENABLE ROW LEVEL SECURITY;

CREATE POLICY "cous_admin_all" ON cous_incidents
  FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('ADMIN','SUPER_ADMIN'))
  );

CREATE POLICY "cous_operator_read" ON cous_incidents
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'OPERATOR')
  );

CREATE TRIGGER cous_incidents_updated_at
  BEFORE UPDATE ON cous_incidents
  FOR EACH ROW EXECUTE FUNCTION moddatetime(updated_at);

ALTER PUBLICATION supabase_realtime ADD TABLE cous_incidents;

-- ──────────────────────────────────────────────
-- 4. ALERTES COUS
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.cous_alertes (
  id          UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  type        TEXT NOT NULL,
  message     TEXT NOT NULL,
  couleur     TEXT DEFAULT '#ef4444',
  niveau      TEXT DEFAULT 'alerte'
              CHECK (niveau IN ('info','alerte','critique')),
  actif       BOOLEAN DEFAULT TRUE,
  incident_id UUID REFERENCES cous_incidents(id) ON DELETE SET NULL,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE cous_alertes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "cous_alertes_admin" ON cous_alertes
  FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('ADMIN','SUPER_ADMIN'))
  );

ALTER PUBLICATION supabase_realtime ADD TABLE cous_alertes;

-- ──────────────────────────────────────────────
-- 5. LITS HOSPITALIERS
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.lits_services (
  id            UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  hopital_id    TEXT NOT NULL,
  hopital_nom   TEXT NOT NULL,
  region        TEXT DEFAULT 'Dakar',
  service       TEXT NOT NULL,
  total         INT NOT NULL CHECK (total > 0),
  disponibles   INT NOT NULL CHECK (disponibles >= 0),
  updated_by    UUID REFERENCES profiles(id) ON DELETE SET NULL,
  updated_at    TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(hopital_id, service)
);

CREATE INDEX ON lits_services(hopital_id);
CREATE INDEX ON lits_services(region);

ALTER TABLE lits_services ENABLE ROW LEVEL SECURITY;

CREATE POLICY "lits_operator_read" ON lits_services
  FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE POLICY "lits_admin_write" ON lits_services
  FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('ADMIN','SUPER_ADMIN'))
  );

CREATE TRIGGER lits_updated_at
  BEFORE UPDATE ON lits_services
  FOR EACH ROW EXECUTE FUNCTION moddatetime(updated_at);

ALTER PUBLICATION supabase_realtime ADD TABLE lits_services;

-- Vue alertes lits
CREATE OR REPLACE VIEW v_lits_alertes AS
  SELECT hopital_nom, service, disponibles, total,
         ROUND(disponibles::numeric/total*100, 1) AS pct_dispo
  FROM lits_services
  WHERE ROUND(disponibles::numeric/total*100, 1) < 15
  ORDER BY pct_dispo ASC;

-- ──────────────────────────────────────────────
-- 6. STOCKS DE SANG
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.sang_stocks (
  id            UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  centre_id     TEXT NOT NULL,
  centre_nom    TEXT NOT NULL,
  type_centre   TEXT NOT NULL CHECK (type_centre IN ('cnts','bts')),
  groupe        TEXT NOT NULL CHECK (groupe IN ('O+','O-','A+','A-','B+','B-','AB+','AB-')),
  stock         INT NOT NULL CHECK (stock >= 0),
  seuil_alerte  INT NOT NULL DEFAULT 10,
  demandes      INT DEFAULT 0,
  updated_by    UUID REFERENCES profiles(id) ON DELETE SET NULL,
  updated_at    TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(centre_id, groupe)
);

CREATE INDEX ON sang_stocks(centre_id);
CREATE INDEX ON sang_stocks(groupe);

ALTER TABLE sang_stocks ENABLE ROW LEVEL SECURITY;

CREATE POLICY "sang_read_all" ON sang_stocks
  FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE POLICY "sang_admin_write" ON sang_stocks
  FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('ADMIN','SUPER_ADMIN'))
  );

CREATE TRIGGER sang_updated_at
  BEFORE UPDATE ON sang_stocks
  FOR EACH ROW EXECUTE FUNCTION moddatetime(updated_at);

ALTER PUBLICATION supabase_realtime ADD TABLE sang_stocks;

-- Vue alertes sang critiques
CREATE OR REPLACE VIEW v_sang_critiques AS
  SELECT centre_nom, groupe, stock, seuil_alerte,
         ROUND(stock::numeric/seuil_alerte, 2) AS ratio
  FROM sang_stocks
  WHERE stock < seuil_alerte
  ORDER BY ratio ASC;

-- ──────────────────────────────────────────────
-- 7. AMBULANCES GPS
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.ambulances (
  id            TEXT PRIMARY KEY,
  nom           TEXT NOT NULL,
  type          TEXT NOT NULL CHECK (type IN ('samu','smur','pompiers','croix_rouge')),
  secteur       TEXT,
  equipement    TEXT DEFAULT 'BLS',
  statut        TEXT DEFAULT 'disponible'
                CHECK (statut IN ('disponible','en_mission','en_maintenance')),
  lat           FLOAT DEFAULT 14.693,
  lon           FLOAT DEFAULT -17.450,
  batterie      INT DEFAULT 100,
  km_total      INT DEFAULT 0,
  conducteur_id UUID REFERENCES profiles(id) ON DELETE SET NULL,
  updated_at    TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE ambulances ENABLE ROW LEVEL SECURITY;
CREATE POLICY "amb_read_operator" ON ambulances FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY "amb_write_admin" ON ambulances
  FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('ADMIN','SUPER_ADMIN'))
  );

CREATE TRIGGER ambulances_updated_at
  BEFORE UPDATE ON ambulances
  FOR EACH ROW EXECUTE FUNCTION moddatetime(updated_at);

ALTER PUBLICATION supabase_realtime ADD TABLE ambulances;

-- Historique GPS
CREATE TABLE IF NOT EXISTS public.ambulances_gps (
  id            UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  ambulance_id  TEXT REFERENCES ambulances(id) ON DELETE CASCADE,
  lat           FLOAT NOT NULL,
  lon           FLOAT NOT NULL,
  vitesse_kmh   FLOAT,
  ts            TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX ON ambulances_gps(ambulance_id, ts DESC);
ALTER TABLE ambulances_gps ENABLE ROW LEVEL SECURITY;
CREATE POLICY "gps_admin" ON ambulances_gps
  FOR ALL USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('ADMIN','SUPER_ADMIN')));

-- ──────────────────────────────────────────────
-- 8. SERVICES D'URGENCE (module ADM)
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.services_urgence (
  id            SERIAL PRIMARY KEY,
  nom           TEXT NOT NULL,
  type          TEXT NOT NULL DEFAULT 'medical',
  telephone     TEXT NOT NULL,
  site          TEXT DEFAULT 'Dakar',
  agents        INT DEFAULT 0,
  statut        TEXT DEFAULT 'actif' CHECK (statut IN ('actif','standby','inactif')),
  created_at    TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE services_urgence ENABLE ROW LEVEL SECURITY;
CREATE POLICY "services_read" ON services_urgence FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY "services_admin" ON services_urgence
  FOR ALL USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('ADMIN','SUPER_ADMIN')));

-- ──────────────────────────────────────────────
-- 9. URGENCES ORSEC (module M2)
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.urgences (
  id            UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  titre         TEXT NOT NULL,
  lieu          TEXT NOT NULL,
  criticite     TEXT NOT NULL CHECK (criticite IN ('P1','P2')),
  statut        TEXT DEFAULT 'ouvert' CHECK (statut IN ('ouvert','en_cours','resolu')),
  declarant_id  UUID REFERENCES profiles(id) ON DELETE SET NULL,
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  resolved_at   TIMESTAMPTZ
);

ALTER TABLE urgences ENABLE ROW LEVEL SECURITY;
CREATE POLICY "urgences_read" ON urgences FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY "urgences_write" ON urgences
  FOR ALL USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('ADMIN','SUPER_ADMIN')));

ALTER PUBLICATION supabase_realtime ADD TABLE urgences;

-- ──────────────────────────────────────────────
-- 10. ACCRÉDITATIONS (module M7)
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.accreditations (
  id        TEXT PRIMARY KEY,
  nom       TEXT NOT NULL,
  pays      TEXT DEFAULT 'SN',
  categorie TEXT NOT NULL CHECK (categorie IN ('A','B','C','D','E','F')),
  sport     TEXT,
  statut    TEXT DEFAULT 'valide' CHECK (statut IN ('valide','suspendu','expire')),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE accreditations ENABLE ROW LEVEL SECURITY;
CREATE POLICY "acc_read" ON accreditations FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY "acc_admin" ON accreditations
  FOR ALL USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('ADMIN','SUPER_ADMIN')));

-- ──────────────────────────────────────────────
-- 11. AUDIT LOG GLOBAL
-- ──────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.audit_logs (
  id          UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id     UUID REFERENCES profiles(id) ON DELETE SET NULL,
  source      TEXT NOT NULL,
  message     TEXT NOT NULL,
  module      TEXT,
  ts          TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX ON audit_logs(ts DESC);
CREATE INDEX ON audit_logs(source, ts DESC);

ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "audit_own" ON audit_logs FOR SELECT USING (user_id = auth.uid());
CREATE POLICY "audit_admin" ON audit_logs
  FOR ALL USING (EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role IN ('ADMIN','SUPER_ADMIN')));

-- ──────────────────────────────────────────────
-- 12. FONCTION : Enregistrer audit depuis client
-- ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION log_action(p_source TEXT, p_message TEXT, p_module TEXT DEFAULT NULL)
RETURNS void AS $$
BEGIN
  INSERT INTO audit_logs (user_id, source, message, module)
  VALUES (auth.uid(), p_source, p_message, p_module);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ══════════════════════════════════════════════
-- DONNÉES INITIALES (SEED DATA)
-- ══════════════════════════════════════════════

-- Lits hospitaliers
INSERT INTO lits_services (hopital_id, hopital_nom, region, service, total, disponibles) VALUES
('CHU-DKR','CHU de Dakar','Dakar','Urgences',40,8),
('CHU-DKR','CHU de Dakar','Dakar','Réanimation',12,2),
('CHU-DKR','CHU de Dakar','Dakar','Chirurgie',80,22),
('CHU-DKR','CHU de Dakar','Dakar','Maternité',60,18),
('CHU-DKR','CHU de Dakar','Dakar','Pédiatrie',50,14),
('CHU-DKR','CHU de Dakar','Dakar','Médecine interne',100,31),
('HOP-FANN','Hôpital Fann','Dakar','Urgences',25,6),
('HOP-FANN','Hôpital Fann','Dakar','Neurologie',40,11),
('HOP-FANN','Hôpital Fann','Dakar','Psychiatrie',80,24),
('HOP-FANN','Hôpital Fann','Dakar','Médecine',60,18),
('HP-PRIN','Hôpital Principal','Dakar','Urgences',30,4),
('HP-PRIN','Hôpital Principal','Dakar','Chirurgie',70,15),
('HP-PRIN','Hôpital Principal','Dakar','Réanimation',10,1),
('HP-PRIN','Hôpital Principal','Dakar','Maternité',40,12),
('HOP-THIES','Hôpital Régional Thiès','Thiès','Urgences',18,5),
('HOP-THIES','Hôpital Régional Thiès','Thiès','Chirurgie',35,12),
('HOP-THIES','Hôpital Régional Thiès','Thiès','Maternité',30,9)
ON CONFLICT (hopital_id, service) DO NOTHING;

-- Stocks de sang
INSERT INTO sang_stocks (centre_id, centre_nom, type_centre, groupe, stock, seuil_alerte, demandes) VALUES
('CNTS-DKR','CNTS Dakar','cnts','O+',142,50,8),
('CNTS-DKR','CNTS Dakar','cnts','O-',18,20,5),
('CNTS-DKR','CNTS Dakar','cnts','A+',87,30,4),
('CNTS-DKR','CNTS Dakar','cnts','A-',11,15,2),
('CNTS-DKR','CNTS Dakar','cnts','B+',64,25,3),
('CNTS-DKR','CNTS Dakar','cnts','B-',9,12,1),
('CNTS-DKR','CNTS Dakar','cnts','AB+',22,10,1),
('CNTS-DKR','CNTS Dakar','cnts','AB-',4,8,0),
('CNTS-THIES','CNTS Thiès','cnts','O+',56,30,2),
('CNTS-THIES','CNTS Thiès','cnts','O-',8,12,1),
('CNTS-THIES','CNTS Thiès','cnts','A+',32,15,1),
('CNTS-THIES','CNTS Thiès','cnts','A-',4,8,0),
('CNTS-THIES','CNTS Thiès','cnts','B+',21,12,1),
('CNTS-THIES','CNTS Thiès','cnts','B-',3,6,0),
('CNTS-THIES','CNTS Thiès','cnts','AB+',8,5,0),
('CNTS-THIES','CNTS Thiès','cnts','AB-',1,4,0),
('BTS-CHU','Banque Sang CHU Dakar','bts','O+',28,20,3),
('BTS-CHU','Banque Sang CHU Dakar','bts','O-',6,10,2),
('BTS-CHU','Banque Sang CHU Dakar','bts','A+',19,12,2),
('BTS-CHU','Banque Sang CHU Dakar','bts','A-',3,7,1),
('BTS-CHU','Banque Sang CHU Dakar','bts','B+',14,10,1),
('BTS-CHU','Banque Sang CHU Dakar','bts','B-',2,5,0),
('BTS-CHU','Banque Sang CHU Dakar','bts','AB+',5,4,0),
('BTS-CHU','Banque Sang CHU Dakar','bts','AB-',1,3,0)
ON CONFLICT (centre_id, groupe) DO NOTHING;

-- Ambulances
INSERT INTO ambulances (id, nom, type, secteur, equipement, statut, lat, lon, batterie) VALUES
('AMB-01','AMB-01 SAMU','samu','Plateau/Médina','BLS','disponible',14.6937,-17.4441,82),
('AMB-02','AMB-02 SAMU','samu','Almadies/Ngor','ALS','en_mission',14.7245,-17.5125,67),
('AMB-03','AMB-03 SAMU','samu','Parcelles/Guédiawaye','BLS','disponible',14.7892,-17.3956,91),
('AMB-04','AMB-04 SMUR','smur','CHU Dakar','Médecin','disponible',14.6823,-17.4362,55),
('AMB-05','AMB-05 SMUR','smur','Hôp. Principal','Médecin','en_mission',14.6901,-17.4412,88),
('FPT-01','FPT-01 Pompiers','pompiers','Caserne Centrale','Secours','disponible',14.6712,-17.4278,95),
('FPT-02','FPT-02 Pompiers','pompiers','Ouakam','Secours','disponible',14.7123,-17.4934,72),
('FPT-03','FPT-03 Pompiers','pompiers','Parcelles','Secours','en_maintenance',14.7845,-17.3823,48),
('CRX-01','CRX-01 Croix-Rouge','croix_rouge','Stade LSS','BLS','disponible',14.7234,-17.3678,78)
ON CONFLICT (id) DO NOTHING;

-- Services d'urgence
INSERT INTO services_urgence (nom, type, telephone, site, agents, statut) VALUES
('SAMU — Base Plateau','medical','15','Plateau Dakar',12,'actif'),
('SAMU — Village Athlètes','medical','15','Village Athlètes',8,'actif'),
('SMUR — CHU Dakar','medical','+221 33 869 00 00','CHU Dakar',6,'actif'),
('Sapeurs-Pompiers Centrale','pompiers','18','Caserne Centrale',32,'actif'),
('Pompiers Parcelles','pompiers','18','Parcelles Assain.',24,'actif'),
('Police Commissariat N1','securite','17','Plateau',45,'actif'),
('Gendarmerie Ouakam','securite','1515','Ouakam',30,'actif'),
('COUS Central','sanitaire','+221 33 839 91 00','Dakar Centre',18,'actif'),
('Croix-Rouge Stade LSS','croixrouge','+221 33 869 11 11','Stade LSS',14,'actif'),
('SOS Médecins SN','medical','800 00 50 50','Dakar mobile',8,'actif')
ON CONFLICT DO NOTHING;

-- Incidents COUS initiaux (démo)
-- Note: signaleur_id sera NULL car pas encore d'utilisateurs
INSERT INTO cous_incidents (type, lieu, gravite, statut, equipes) VALUES
('Accident route','VDN km12','critique','en_cours','{"AMB-02 SAMU","FPT-01 Pompiers"}'),
('Malaise collectif','Stade LSS','urgent','en_cours','{"AMB-01 SAMU"}'),
('Intoxication alimentaire','Village Athlètes','modere','en_surveillance','{"COUS Mobile"}')
ON CONFLICT DO NOTHING;

-- Alertes COUS initiales
INSERT INTO cous_alertes (type, message, couleur, niveau) VALUES
('STOCK_SANG','CNTS Dakar: O- sous seuil critique (18 poches)','#ef4444','critique'),
('LITS','CHU Dakar Réanimation: 1 lit disponible sur 12','#ef4444','critique'),
('METEO','Chaleur extrême prévue 15h — Risque coup de chaleur','#eab308','alerte')
ON CONFLICT DO NOTHING;

-- Accréditations
INSERT INTO accreditations (id, nom, pays, categorie, sport, statut) VALUES
('ACC-0001','Amadou Diallo','SN','A','Athlétisme','valide'),
('ACC-0002','Sarah Johnson','USA','A','Natation','valide'),
('ACC-0003','Pierre Martin','FR','C','Presse','valide'),
('ACC-0004','Yuki Tanaka','JP','A','Judo','suspendu'),
('ACC-0005','Ali Hassan','EG','B','Staff CIO','valide'),
('ACC-0006','Fatou Ndiaye','SN','E','Personnel','valide')
ON CONFLICT (id) DO NOTHING;

-- ══════════════════════════════════════════════
-- UTILISATEURS DE TEST (à créer via Supabase Auth)
-- ══════════════════════════════════════════════
-- Créer ces utilisateurs dans Supabase > Authentication > Users
-- Puis exécuter ces inserts pour assigner les rôles :
--
-- UPDATE profiles SET nom='Coordinateur JOJ', role='SUPER_ADMIN' WHERE id = (SELECT id FROM auth.users WHERE email='admin@nexkord.sn');
-- UPDATE profiles SET nom='Admin COUS', role='ADMIN' WHERE id = (SELECT id FROM auth.users WHERE email='cous@nexkord.sn');
-- UPDATE profiles SET nom='Oumar Diallo', role='OPERATOR', axe='VDN', certif='PSC1' WHERE id = (SELECT id FROM auth.users WHERE email='oumar@nexkord.sn');
-- UPDATE profiles SET nom='Fatou Sow', role='OPERATOR', axe='Corniche', certif='PSC1' WHERE id = (SELECT id FROM auth.users WHERE email='fatou@nexkord.sn');
-- UPDATE profiles SET nom='Partenaire ONG', role='VIEWER' WHERE id = (SELECT id FROM auth.users WHERE email='ong@nexkord.sn');

-- ══════════════════════════════════════════════
-- VÉRIFICATION FINALE
-- ══════════════════════════════════════════════
SELECT 'lits_services' as table_name, COUNT(*) as rows FROM lits_services
UNION ALL SELECT 'sang_stocks', COUNT(*) FROM sang_stocks
UNION ALL SELECT 'ambulances', COUNT(*) FROM ambulances
UNION ALL SELECT 'services_urgence', COUNT(*) FROM services_urgence
UNION ALL SELECT 'cous_incidents', COUNT(*) FROM cous_incidents
UNION ALL SELECT 'cous_alertes', COUNT(*) FROM cous_alertes
UNION ALL SELECT 'accreditations', COUNT(*) FROM accreditations;
