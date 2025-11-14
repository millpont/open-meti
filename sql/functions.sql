-- METI™ DATABASE FUNCTIONS
-- NOTE: These functions assume PostGIS is installed and that the following
-- tables exist in your schema: profiles, accounts, account_profiles,
-- countries, function_logs, sources, sources_queue.

-- add_user_to_account_by_email
CREATE OR REPLACE FUNCTION public.add_user_to_account_by_email(
    user_email text,
    account_id uuid,
    user_role text
) RETURNS void AS $$
DECLARE
    profile_id uuid;
BEGIN
    SELECT id INTO profile_id
    FROM public.profiles
    WHERE email = user_email;

    IF profile_id IS NULL THEN
        RAISE EXCEPTION 'User with email % does not exist', user_email;
    END IF;

    INSERT INTO public.account_profiles (account_id, profile_id, role)
    VALUES (account_id, profile_id, user_role);
END;
$$ LANGUAGE plpgsql;


-- check_role_in_account
CREATE OR REPLACE FUNCTION public.check_role_in_account(
    user_profile_id uuid,
    account_uuid uuid,
    required_role text
) RETURNS boolean AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1
        FROM account_profiles ap
        WHERE ap.profile_id = user_profile_id
          AND ap.account_id = account_uuid
          AND ap.role = required_role
    );
END;
$$ LANGUAGE plpgsql;


-- compare_encrypted_values
CREATE OR REPLACE FUNCTION public.compare_encrypted_values(
    a text,
    b text
) RETURNS integer AS $$
BEGIN
    IF a < b THEN
        RETURN -1;
    ELSIF a > b THEN
        RETURN 1;
    ELSE
        RETURN 0;
    END IF;
END;
$$ LANGUAGE plpgsql;


-- delete_after_update (used to hard-delete rows marked `to_delete = true`)
CREATE OR REPLACE FUNCTION public.delete_after_update()
RETURNS trigger AS $$
BEGIN
    IF NEW.to_delete = TRUE THEN
        DELETE FROM public.sources WHERE id = NEW.id;
        RETURN NULL;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- delete_marked_sources (batch cleanup helper)
CREATE OR REPLACE FUNCTION public.delete_marked_sources()
RETURNS void AS $$
BEGIN
    DELETE FROM public.sources
    WHERE to_delete = true;
END;
$$ LANGUAGE plpgsql;


-- do_polygons_overlap (GeoJSON-based)
CREATE OR REPLACE FUNCTION public.do_polygons_overlap(
    poly1 jsonb,
    poly2 jsonb
) RETURNS boolean AS $$
DECLARE
    point jsonb;
    i int;
    poly1_points int := jsonb_array_length(poly1->'geometry'->'coordinates'->0);
    poly2_points int := jsonb_array_length(poly2->'geometry'->'coordinates'->0);
BEGIN
    -- Check if any point of poly1 is inside poly2
    FOR i IN 0..poly1_points-1 LOOP
        point := poly1->'geometry'->'coordinates'->0->i;
        IF is_point_inside_polygon(point, poly2) THEN
            RETURN TRUE;
        END IF;
    END LOOP;

    -- Check if any point of poly2 is inside poly1
    FOR i IN 0..poly2_points-1 LOOP
        point := poly2->'geometry'->'coordinates'->0->i;
        IF is_point_inside_polygon(point, poly1) THEN
            RETURN TRUE;
        END IF;
    END LOOP;

    RETURN FALSE;
END;
$$ LANGUAGE plpgsql;


-- handle_new_user (example Supabase-style auth hook)
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger AS $$
BEGIN
    INSERT INTO public.profiles (id, first_name, last_name, email)
    VALUES (
        NEW.id,
        NEW.raw_user_meta_data ->> 'given_name',
        NEW.raw_user_meta_data ->> 'family_name',
        NEW.email
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- is_point_inside_polygon
CREATE OR REPLACE FUNCTION public.is_point_inside_polygon(
    point jsonb,
    polygon jsonb
) RETURNS boolean AS $$
DECLARE
    inside boolean := FALSE;
    p1 jsonb;
    p2 jsonb;
    i int;
    polygon_points int :=
        jsonb_array_length(polygon->'geometry'->'coordinates'->0);
BEGIN
    FOR i IN 0..polygon_points-1 LOOP
        p1 := polygon->'geometry'->'coordinates'->0->i;
        p2 := polygon->'geometry'->'coordinates'->0->((i + 1) % polygon_points);

        IF ((compare_encrypted_values(p1->>1, point->>1) > 0) <>
            (compare_encrypted_values(p2->>1, point->>1) > 0))
           AND (compare_encrypted_values(point->>0, p1->>0) > 0)
           AND (compare_encrypted_values(point->>0, p2->>0) > 0)
        THEN
            inside := NOT inside;
        END IF;
    END LOOP;

    RETURN inside;
END;
$$ LANGUAGE plpgsql;


-- process_feature_collection: validate and fan-out queue features into sources
CREATE OR REPLACE FUNCTION public.process_feature_collection()
RETURNS trigger AS $$
DECLARE
    v_account_id uuid;
    invalid_feature_count int;
BEGIN
    -- Log the function start
    INSERT INTO function_logs (log_time, message)
    VALUES (NOW(), 'process_feature_collection function started for sources_queue ID ' || NEW.id);

    -- Step 1: Validate the overall structure of the FeatureCollection
    IF NOT (NEW.feature_collection ? 'type' AND NEW.feature_collection->>'type' = 'FeatureCollection') THEN
        RAISE EXCEPTION 'Invalid FeatureCollection format: "type" field must be "FeatureCollection".';
    END IF;

    IF jsonb_typeof(NEW.feature_collection->'features') IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'Invalid FeatureCollection format: "features" field must be an array.';
    END IF;

    -- Step 2: Retrieve the account_id associated with created_by
    SELECT ap.account_id INTO v_account_id
    FROM account_profiles AS ap
    WHERE ap.profile_id = NEW.created_by
    LIMIT 1;

    IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'Account ID not found for profile_id %', NEW.created_by;
    END IF;

    -- Step 3: Insert features into a temporary table for validation and processing
    CREATE TEMP TABLE temp_features AS
    SELECT
        ST_GeomFromGeoJSON(feature->>'geometry') AS geometry,
        feature->>'id' AS alt_id,
        (feature->'properties'->>'start_at')::timestamptz AS start_at,
        (feature->'properties'->>'end_at')::timestamptz AS end_at,
        feature AS geojson
    FROM jsonb_array_elements(NEW.feature_collection->'features') AS feature;

    -- Step 4: Count invalid features in the temporary table
    SELECT COUNT(*) INTO invalid_feature_count
    FROM temp_features
    WHERE geometry IS NULL OR NOT ST_IsValid(geometry)
       OR start_at IS NULL OR end_at IS NULL
       OR end_at <= start_at + interval '1 day';

    -- Step 5: Raise an exception if any feature is invalid or missing required fields
    IF invalid_feature_count > 0 THEN
        DROP TABLE temp_features;
        RAISE EXCEPTION 'One or more features in the FeatureCollection are invalid or missing required fields.';
    END IF;

    -- Step 6: Insert all validated features into the sources table
    INSERT INTO sources (
        geometry, alt_id, start_at, end_at,
        created_by, updated_by, account_id, geojson
    )
    SELECT
        geometry,
        alt_id,
        start_at,
        end_at,
        NEW.created_by,
        NEW.created_by,
        v_account_id,
        geojson
    FROM temp_features;

    DROP TABLE temp_features;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;


-- remove_conflict_id_on_delete
CREATE OR REPLACE FUNCTION public.remove_conflict_id_on_delete()
RETURNS trigger AS $$
BEGIN
    IF OLD.conflict THEN
        UPDATE public.sources
        SET conflict_with = array_remove(conflict_with, OLD.id::text)
        WHERE OLD.id::text = ANY(conflict_with);

        UPDATE public.sources
        SET conflict = FALSE
        WHERE array_length(conflict_with, 1) IS NULL
           OR array_length(conflict_with, 1) = 0;
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;


-- remove_user_from_account_by_email
CREATE OR REPLACE FUNCTION public.remove_user_from_account_by_email(
    input_user_email text,
    input_account_id uuid
) RETURNS void AS $$
DECLARE
    user_profile_id uuid;
    caller_is_admin boolean;
BEGIN
    -- Check if the current user is an admin for the specified account
    SELECT EXISTS (
        SELECT 1
        FROM public.account_profiles ap
        WHERE ap.profile_id = auth.uid()
          AND ap.account_id = input_account_id
          AND ap.role = 'admin'
    ) INTO caller_is_admin;

    IF NOT caller_is_admin THEN
        RAISE EXCEPTION 'Only admins can remove users from accounts';
    END IF;

    -- Get the profile_id of the user to be removed by their email
    SELECT p.id INTO user_profile_id
    FROM public.profiles p
    WHERE p.email = input_user_email;

    IF user_profile_id IS NULL THEN
        RAISE EXCEPTION 'User with email % does not exist', input_user_email;
    END IF;

    DELETE FROM public.account_profiles ap
    WHERE ap.account_id = input_account_id
      AND ap.profile_id = user_profile_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No entry found for user with email % in account %',
            input_user_email, input_account_id;
    END IF;
END;
$$ LANGUAGE plpgsql;


-- set_created_by (for sources_queue)
CREATE OR REPLACE FUNCTION public.set_created_by()
RETURNS trigger AS $$
BEGIN
    NEW.created_by = auth.uid();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- sources_after_insert: recompute conflicts and percent_overlap for neighbors
CREATE OR REPLACE FUNCTION public.sources_after_insert()
RETURNS trigger AS $$
BEGIN
    IF NEW.conflict THEN
        -- Update conflicting rows to ensure reciprocal conflict_with entries
        UPDATE public.sources
        SET
            conflict = TRUE,
            conflict_with = ARRAY(
                SELECT DISTINCT UNNEST(COALESCE(conflict_with, ARRAY[]::text[]))
                UNION ALL
                SELECT NEW.id::text
            )
        WHERE NEW.conflict_with IS NOT NULL
          AND id::text = ANY(NEW.conflict_with);

        -- Recompute percent_overlap for impacted rows
        UPDATE public.sources s
        SET percent_overlap = (
            WITH const AS (SELECT 6933 AS srid),
            s_planar AS (
                SELECT ST_Transform(s.geometry, (SELECT srid FROM const)) AS g
            ),
            u AS (
                SELECT ST_UnaryUnion(
                    ST_Collect(
                        ST_Intersection(
                            ST_Transform(o.geometry, (SELECT srid FROM const)),
                            (SELECT g FROM s_planar)
                        )
                    )
                ) AS g
                FROM public.sources o
                WHERE o.id <> s.id
                  AND o.country = s.country
                  AND o.id::text = ANY (s.conflict_with)
                  AND s.id::text = ANY (o.conflict_with)
                  AND tstzrange(o.start_at, o.end_at) && tstzrange(s.start_at, s.end_at)
                  AND ST_Intersects(o.geometry, s.geometry)
            )
            SELECT CASE
                WHEN ST_Area((SELECT g FROM s_planar)) = 0 THEN NULL
                ELSE LEAST(
                    1.0,
                    GREATEST(
                        0.0,
                        COALESCE(ST_Area((SELECT g FROM u)), 0.0) / ST_Area((SELECT g FROM s_planar))
                    )
                )
            END
        )
        WHERE NEW.conflict_with IS NOT NULL
          AND id::text = ANY(NEW.conflict_with)
          AND ST_Intersects(geometry, NEW.geometry);
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- sources_before_delete: clean up conflict arrays and recompute overlap
CREATE OR REPLACE FUNCTION public.sources_before_delete()
RETURNS trigger AS $$
BEGIN
    -- Update conflict_with arrays on neighbors
    UPDATE public.sources
    SET
        conflict_with = array_remove(conflict_with, OLD.id::text),
        conflict = array_remove(conflict_with, OLD.id::text) != '{}'
    WHERE id <> OLD.id
      AND conflict_with @> ARRAY[OLD.id::text];

    -- Recompute percent_overlap for affected neighbors
    UPDATE public.sources s
    SET percent_overlap = CASE
        WHEN (s.conflict IS FALSE)
          OR (s.conflict_with IS NULL)
          OR (array_length(s.conflict_with, 1) = 0)
        THEN NULL
        ELSE (
            WITH const AS (SELECT 6933 AS srid),
            s_planar AS (
                SELECT ST_Transform(s.geometry, (SELECT srid FROM const)) AS g
            ),
            u AS (
                SELECT ST_UnaryUnion(
                    ST_Collect(
                        ST_Intersection(
                            ST_Transform(o.geometry, (SELECT srid FROM const)),
                            (SELECT g FROM s_planar)
                        )
                    )
                ) AS g
                FROM public.sources o
                WHERE o.id <> s.id
                  AND o.id <> OLD.id
                  AND o.country = s.country
                  AND tstzrange(o.start_at, o.end_at) && tstzrange(s.start_at, s.end_at)
                  AND ST_Intersects(o.geometry, s.geometry)
            )
            SELECT CASE
                WHEN ST_Area((SELECT g FROM s_planar)) = 0 THEN NULL
                ELSE LEAST(
                    1.0,
                    GREATEST(
                        0.0,
                        COALESCE(ST_Area((SELECT g FROM u)), 0.0) / ST_Area((SELECT g FROM s_planar))
                    )
                )
            END
        )
    END
    WHERE s.id <> OLD.id
      AND s.country = OLD.country
      AND tstzrange(s.start_at, s.end_at) && tstzrange(OLD.start_at, OLD.end_at)
      AND ST_Intersects(s.geometry, OLD.geometry);

    RETURN OLD;
END;
$$ LANGUAGE plpgsql;


-- sources_before_insert: derive country/centroid/area, detect conflicts & percent_overlap
CREATE OR REPLACE FUNCTION public.sources_before_insert()
RETURNS trigger AS $$
DECLARE
    v_centroid geometry;
    v_country_name text;
    v_area float8;
    v_conflict_row record;
    v_account_id uuid;
    c_equal_area_srid constant int := 6933;
    v_new_planar geometry;
    v_union_intersections geometry;
    v_new_area_planar float8;
    v_overlap_area_planar float8;
BEGIN
    -- Populate geometry from geojson
    NEW.geometry := ST_SetSRID(ST_GeomFromGeoJSON(NEW.geojson->>'geometry'), 4326);

    -- Area in hectares (spheroidal)
    v_area := ST_Area(NEW.geometry::geography, true) / 10000.0;
    NEW.hectares := v_area;

    -- Centroid
    v_centroid := ST_Centroid(NEW.geometry);
    NEW.centroid := v_centroid;

    -- Country via centroid-in-country polygon
    SELECT name INTO v_country_name
    FROM public.countries
    WHERE ST_Contains(geom, v_centroid)
    LIMIT 1;

    NEW.country := v_country_name;

    -- Account id from created_by
    SELECT account_id INTO v_account_id
    FROM public.account_profiles
    WHERE profile_id = NEW.created_by
    LIMIT 1;

    NEW.account_id := v_account_id;

    -- Reset conflict flags
    NEW.conflict := FALSE;
    NEW.conflict_with := ARRAY[]::text[];

    -- Find conflicts (spatiotemporal + spatial intersection with a small negative buffer)
    FOR v_conflict_row IN
        SELECT id::text AS id
        FROM public.sources
        WHERE country = NEW.country
          AND tstzrange(start_at, end_at) && tstzrange(NEW.start_at, NEW.end_at)
          AND ST_Intersects(
                geometry,
                ST_Buffer(NEW.geometry::geography, -9)::geometry
              )
    LOOP
        IF NEW.conflict IS NULL OR NEW.conflict = FALSE THEN
            NEW.conflict := TRUE;
        END IF;

        NEW.conflict_with := array_append(
            NEW.conflict_with::text[],
            v_conflict_row.id
        );
    END LOOP;

    IF NEW.conflict THEN
        v_new_planar := ST_Transform(NEW.geometry, c_equal_area_srid);
        v_new_area_planar := NULLIF(ST_Area(v_new_planar), 0.0);

        SELECT ST_UnaryUnion(
            ST_Collect(
                ST_Intersection(
                    ST_Transform(s.geometry, c_equal_area_srid),
                    v_new_planar
                )
            )
        )
        INTO v_union_intersections
        FROM public.sources s
        WHERE s.id::text = ANY (NEW.conflict_with)
          AND tstzrange(s.start_at, s.end_at) && tstzrange(NEW.start_at, NEW.end_at)
          AND ST_Intersects(s.geometry, NEW.geometry);

        v_overlap_area_planar := COALESCE(ST_Area(v_union_intersections), 0.0);

        NEW.percent_overlap := CASE
            WHEN v_new_area_planar IS NULL THEN NULL
            ELSE LEAST(1.0, GREATEST(0.0, v_overlap_area_planar / v_new_area_planar))
        END;
    ELSE
        NEW.percent_overlap := NULL;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- sources_before_update: recalc conflict list when geometry or time changes
CREATE OR REPLACE FUNCTION public.sources_before_update()
RETURNS trigger AS $$
DECLARE
    v_conflict_row record;
BEGIN
    -- Avoid recursion
    IF pg_trigger_depth() > 1 THEN
        RETURN NEW;
    END IF;

    NEW.conflict := FALSE;
    NEW.conflict_with := NULL;

    FOR v_conflict_row IN
        SELECT id
        FROM public.sources
        WHERE country = NEW.country
          AND tstzrange(start_at, end_at) && tstzrange(NEW.start_at, NEW.end_at)
          AND ST_Intersects(
                geometry,
                ST_Buffer(NEW.geometry::geography, -9)::geometry
              )
          AND id <> NEW.id
    LOOP
        IF NEW.conflict IS NULL OR NEW.conflict = FALSE THEN
            NEW.conflict := TRUE;
        END IF;

        NEW.conflict_with := array_append(
            COALESCE(NEW.conflict_with, ARRAY[]::text[]),
            v_conflict_row.id::text
        );
    END LOOP;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
