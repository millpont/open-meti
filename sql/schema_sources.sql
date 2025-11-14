-- METI™ SOURCES TABLE SCHEMA

CREATE TABLE IF NOT EXISTS public.sources (
    id text NOT NULL DEFAULT (
        'src_'::text ||
        SUBSTRING(
            replace(
                replace(
                    replace(
                        encode(extensions.gen_random_bytes(12), 'base64'::text),
                        '+'::text,
                        'A'::text
                    ),
                    '/'::text,
                    'B'::text
                ),
                '='::text,
                ''::text
            )
            FROM 1 FOR 13
        )
    ),
    start_at timestamp with time zone NOT NULL,
    end_at timestamp with time zone NOT NULL,
    country text NULL,
    hectares numeric NULL,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    updated_at timestamp with time zone NOT NULL DEFAULT now(),
    created_by uuid NOT NULL,
    updated_by uuid NOT NULL,
    conflict boolean NOT NULL DEFAULT false,
    alt_id text NOT NULL,
    encrypted_geometry jsonb NULL,
    account_id uuid NULL,
    conflict_with text[] NULL,
    geometry geometry NULL,
    geojson json NOT NULL,
    centroid geometry NULL,
    to_delete boolean NOT NULL DEFAULT false,
    tags text[] NULL,
    unep_overlap boolean NULL DEFAULT false,
    pa_name text NULL,
    pa_designation text NULL,
    wdpaid text NULL,
    h3_indexes text[] NULL,
    methodology character varying(255) NULL,
    percent_overlap double precision NULL,
    CONSTRAINT sources_pkey PRIMARY KEY (id),
    CONSTRAINT sources_account_id_fkey FOREIGN KEY (account_id) REFERENCES accounts (id),
    CONSTRAINT sources_created_by_fkey FOREIGN KEY (created_by) REFERENCES profiles (id),
    CONSTRAINT sources_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES profiles (id),
    CONSTRAINT sources_id_check CHECK ((id ~ '^src_[A-Za-z0-9]{13}$'::text)),
    CONSTRAINT sources_alt_id_check CHECK ((length(alt_id) < 50)),
    CONSTRAINT end_after_start_check CHECK ((end_at > start_at))
) TABLESPACE pg_default;

CREATE INDEX IF NOT EXISTS idx_sources_geometry
    ON public.sources USING gist (geometry);

CREATE INDEX IF NOT EXISTS idx_sources_dates
    ON public.sources USING gist (tstzrange(start_at, end_at));

CREATE INDEX IF NOT EXISTS idx_sources_timerange
    ON public.sources USING gist (tstzrange(start_at, end_at));

CREATE INDEX IF NOT EXISTS idx_sources_conflicts_vcm
    ON public.sources USING btree (account_id, conflict, to_delete)
    TABLESPACE pg_default
    WHERE ((conflict = true) AND (to_delete IS DISTINCT FROM true));

CREATE INDEX IF NOT EXISTS idx_sources_search_vcm
    ON public.sources USING btree (account_id, id, alt_id)
    TABLESPACE pg_default
    WHERE ((conflict = true) AND (to_delete IS DISTINCT FROM true));

CREATE INDEX IF NOT EXISTS idx_sources_conflict_with
    ON public.sources USING gin (conflict_with)
    TABLESPACE pg_default;

CREATE INDEX IF NOT EXISTS idx_sources_account_conflict
    ON public.sources USING btree (account_id, conflict)
    TABLESPACE pg_default
    WHERE (conflict = true);

CREATE INDEX IF NOT EXISTS idx_sources_account_id
    ON public.sources USING btree (account_id)
    TABLESPACE pg_default;

CREATE INDEX IF NOT EXISTS idx_sources_country
    ON public.sources USING btree (country)
    TABLESPACE pg_default;
