-- =====================================================================
--  Sanchari · 07a_seed_users.sql
--  Purpose    : Load users, traveller profiles and interests from three
--               CSV files in db/data/.
--  Author     : Swara
--  Runs after : 06a_seed_reference.sql  (needs role and interest_category)
--
--  users.csv               email, display_name, home_city, role,
--                          password, date_joined
--  traveller_profiles.csv  email, default_pace, max_daily_budget,
--                          max_travel_hours_per_day, day_start_time,
--                          day_end_time
--  traveller_interests.csv email, category_slug, weight (1-5)
--
--  The people are invented; every email uses the reserved @example.com
--  domain. 1 Admin, 2 Curators, 27 Travellers. 25 of the 27 travellers
--  have a profile - two deliberately do not, because the ER diagram says
--  a user MAY have a profile (partial participation in HAS_PROFILE).
--
--  PASSWORDS: the CSV holds the plain demo password; it is hashed here
--  with bcrypt (pgcrypto's crypt + gen_salt('bf')) and only the hash is
--  stored. Every seed account's password is Sanchari@2026.
-- =====================================================================


-- #####################################################################
--  1. user_account
-- #####################################################################
CREATE TEMP TABLE stg_user (
    email         TEXT,
    display_name  TEXT,
    home_city     TEXT,
    role          TEXT,
    password      TEXT,
    date_joined   DATE
);

\copy stg_user FROM '/db/data/users.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

DO $$
DECLARE bad TEXT;
BEGIN
    SELECT string_agg(DISTINCT s.role, ', ') INTO bad
      FROM stg_user s LEFT JOIN role r ON r.role_name = s.role
     WHERE r.role_id IS NULL;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'users.csv uses roles that do not exist: %', bad;
    END IF;
END $$;

INSERT INTO user_account (role_id, email, password_hash, display_name,
                          home_city, date_joined)
SELECT r.role_id,
       lower(trim(s.email)),
       crypt(s.password, gen_salt('bf', 8)),     -- bcrypt, cost 8
       trim(s.display_name),
       trim(s.home_city),
       s.date_joined::TIMESTAMPTZ
FROM   stg_user s
JOIN   role     r ON r.role_name = s.role;

DROP TABLE stg_user;


-- #####################################################################
--  2. traveller_profile  (1:1 with user_account)
-- #####################################################################
CREATE TEMP TABLE stg_profile (
    email                     TEXT,
    default_pace              TEXT,
    max_daily_budget          NUMERIC,
    max_travel_hours_per_day  NUMERIC,
    day_start_time            TIME,
    day_end_time              TIME
);

\copy stg_profile FROM '/db/data/traveller_profiles.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

DO $$
DECLARE bad TEXT;
BEGIN
    SELECT string_agg(s.email, ', ') INTO bad
      FROM stg_profile s LEFT JOIN user_account u ON u.email = lower(trim(s.email))
     WHERE u.user_id IS NULL;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'traveller_profiles.csv names users not in users.csv: %', bad;
    END IF;
END $$;

INSERT INTO traveller_profile (user_id, default_pace, max_daily_budget,
                               max_travel_hours_per_day, day_start_time, day_end_time)
SELECT u.user_id, s.default_pace, s.max_daily_budget,
       s.max_travel_hours_per_day, s.day_start_time, s.day_end_time
FROM   stg_profile  s
JOIN   user_account u ON u.email = lower(trim(s.email));

DROP TABLE stg_profile;


-- #####################################################################
--  3. traveller_interest  (M:N between profile and category)
-- #####################################################################
CREATE TEMP TABLE stg_interest (
    email          TEXT,
    category_slug  TEXT,
    weight         NUMERIC
);

\copy stg_interest FROM '/db/data/traveller_interests.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

DO $$
DECLARE bad TEXT;
BEGIN
    SELECT string_agg(DISTINCT s.category_slug, ', ') INTO bad
      FROM stg_interest s LEFT JOIN interest_category ic ON ic.slug = s.category_slug
     WHERE ic.category_id IS NULL;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'traveller_interests.csv uses unknown category slugs: %', bad;
    END IF;
    SELECT string_agg(DISTINCT s.email, ', ') INTO bad
      FROM stg_interest s
      LEFT JOIN user_account u      ON u.email = lower(trim(s.email))
      LEFT JOIN traveller_profile p ON p.user_id = u.user_id
     WHERE p.profile_id IS NULL;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'traveller_interests.csv names users without a profile: %', bad;
    END IF;
END $$;

INSERT INTO traveller_interest (profile_id, category_id, weight)
SELECT p.profile_id, ic.category_id, s.weight
FROM   stg_interest      s
JOIN   user_account      u  ON u.email = lower(trim(s.email))
JOIN   traveller_profile p  ON p.user_id = u.user_id
JOIN   interest_category ic ON ic.slug = s.category_slug;

DROP TABLE stg_interest;

-- =====================================================================
--  Sanity check:
--      SELECT r.role_name, count(*) FROM user_account u JOIN role r USING (role_id)
--      GROUP BY r.role_name;                          -- Admin 1, Curator 2, Traveller 27
--
--      -- logging in = comparing a typed password with the stored hash:
--      SELECT display_name FROM user_account
--      WHERE  email = 'ananya.rao@example.com'
--        AND  password_hash = crypt('Sanchari@2026', password_hash);   -- 1 row
-- =====================================================================
