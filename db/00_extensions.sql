-- =====================================================================
--  Sanchari · 00_extensions.sql
--  Purpose    : Enable the PostgreSQL extensions the schema depends on.
--  Author     : Swara + <teammate>   (agreed jointly, Step 2)
--  Runs after : nothing — this is the first file run_all.sql calls.
-- =====================================================================

-- pgvector: adds the VECTOR column type and the similarity operators
-- (<=> cosine, <-> L2, <#> inner product). Needed by place_embedding.
CREATE EXTENSION IF NOT EXISTS vector;

-- btree_gist: lets a GiST index mix ordinary scalar columns with range
-- columns. We need it later for closure_window, where we want to index
-- "this place, over this date range" in one index. Enabling it now costs
-- nothing and saves a migration later.
CREATE EXTENSION IF NOT EXISTS btree_gist;
