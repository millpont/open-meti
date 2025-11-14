# METI™ Source Ledger – Database Schema & Functions

> Geospatial + temporal ledger for polygon-based environmental source data.

This repository contains the PostgreSQL + PostGIS schema, functions, and
triggers that power the **METI™ Source Ledger**. It is focused on
server-side logic: ingestion, validation, conflict detection, and overlap
computation for geospatial source polygons over time.

---

## 📂 Repository Structure

```text
meti-source-ledger/
├── LICENSE
├── README.md
└── sql/
    ├── meti.sql                 # One-shot entrypoint (includes all others)
    ├── schema_sources.sql       # `public.sources` table, indexes & constraints
    ├── schema_sources_queue.sql # `public.sources_queue` table
    ├── functions.sql            # All PL/pgSQL functions
    └── triggers.sql             # All triggers wired to tables
```

- **Prefer editing the split files** under `sql/` during development.
- **Use `meti.sql`** when you want a single entrypoint to bootstrap a
  database (for example, in CI or when quickly spinning up a new instance).

---

## 🚀 Getting Started

### Prerequisites

- PostgreSQL 14+ (recommended)
- PostGIS extension installed in your database
- Supporting tables referenced here (e.g. `profiles`, `accounts`,
  `account_profiles`, `countries`, `function_logs`) should exist in your
  schema. They are not defined in this repo.

### 1. Load Everything

From `psql` or a migration tool that understands `\i`:

```sql
\i sql/meti.sql;
```

This will:

1. Create the `public.sources` and `public.sources_queue` tables
2. Create indexes and constraints
3. Register all functions
4. Wire up triggers

### 2. Minimal Example: Ingest a FeatureCollection

1. Insert a valid GeoJSON FeatureCollection into `sources_queue`:

   ```sql
   INSERT INTO public.sources_queue (feature_collection, created_by)
   VALUES ('{...your FeatureCollection json...}'::jsonb, '<creator-uuid>');
   ```

2. The `process_features_after` trigger calls
   `process_feature_collection`, which:
   - Validates the FeatureCollection structure
   - Validates each feature geometry (`ST_IsValid`)
   - Ensures timestamps are present and that `end_at > start_at + 1 day`
   - Inserts rows into `public.sources` with the correct account context

3. `sources_before_insert` & `sources_after_insert` will then:
   - Compute area (hectares)
   - Compute centroid and country
   - Detect spatiotemporal conflicts with existing sources
   - Compute `percent_overlap` for conflicting polygons

---

## 🧠 Key Concepts

### Spatiotemporal Conflicts

The `public.sources` table tracks overlapping polygons with overlapping
active time ranges. For a given row:

- `conflict` – boolean flag indicating whether this source overlaps others
- `conflict_with` – array of `id`s for conflicting sources
- `percent_overlap` – scalar in `[0,1]`, representing the proportion of
  the subject polygon area that overlaps its conflicting neighbors (computed
  using an equal-area SRID).

### Ingestion Queue

- `public.sources_queue` is a simple queue table for raw FeatureCollections.
- `process_feature_collection()` is the workhorse function that unpacks
  the collection into individual rows in `public.sources`.
- The triggers ensure that any insert into `sources_queue` automatically
  flows through the validation pipeline.

---

## 🧪 Development Tips

- If you want to experiment, run the SQL in a scratch database first.
- All functions are written in PL/pgSQL and should be portable across
  PostgreSQL versions, provided PostGIS is available.
- When changing logic:
  - Prefer modifying `functions.sql` and `triggers.sql`
  - Regenerate or re-run `meti.sql` as necessary

---

## 📜 License

This project is licensed under the MIT License – see [`LICENSE`](./LICENSE)
for details.

---

## 🤝 Contributing

Issues and pull requests are welcome. If you are adopting METI Source
Ledger in production or research, feel free to open an issue and share
your use case.
