-- =============================================================================
-- CymbalGoal Lab 2 — Tier 2: the ai.* family and proxy models on PostgreSQL 18.
--
-- WHERE: psql or AlloyDB Studio against the cymbalgoal database, after the
--        Task 0 load has finished.
-- RUN:   psql -X -P pager=off -f lab2-05-ai-functions.sql 2>&1 | tee ~/lab2-ai.log
--
-- ⚠️ THE ONE THAT CAN KILL HALF OF TASK 6.
-- Google's cost-optimized-AI-functions page states NO PostgreSQL version
-- requirement at all, while the sibling feature (enable_ai_function_acceleration)
-- is documented as PostgreSQL 17 ONLY. If proxy models turn out to be 17-only
-- too, Task 6's second half has no feature and must be rescoped. Section 4
-- settles it. Run this before anyone writes a word of Task 6.
--
-- S-37: this file is deliberately built out of CATALOG INTROSPECTION rather than
-- remembered signatures. Lab 1 shipped a fabricated ai.hybrid_search() signature
-- because someone trusted their memory, and the introspection version of that
-- task turned out to be better pedagogy than the version that guessed right
-- would have been. Same move here.
-- =============================================================================

\timing on

-- -----------------------------------------------------------------------------
\echo '### 1. Versions and flags — the floor everything else depends on ###'
-- -----------------------------------------------------------------------------
-- Extension version floors we carry: 1.5.2 for ai.if/ai.generate, 1.5.4 for the
-- array variants, 1.5.7 for ai.summarize/ai.analyze_sentiment, 1.5.8 for proxy
-- models. What PG 18 actually SHIPS is unpublished — no release note gives a
-- google_ml_integration version past 1.4.2. So we ask.
SELECT version() AS pg_version;
SELECT extname, extversion FROM pg_extension WHERE extname IN
  ('google_ml_integration','vector','alloydb_scann','pg_textsearch')
ORDER BY extname;

\echo '>>> If google_ml_integration < 1.5.8, proxy models are unavailable REGARDLESS'
\echo '>>> of the flag, and ALTER EXTENSION google_ml_integration UPDATE; is the fix.'

SELECT name, setting, source FROM pg_settings
WHERE name LIKE 'google_ml_integration%' ORDER BY name;

\echo '>>> enable_cost_optimized_ai_functions must read on. It is set as an instance'
\echo '>>> database_flag in Terraform; if it reads off here, the flag name changed or'
\echo '>>> the instance did not take it — either way stop and fix Terraform.'

-- -----------------------------------------------------------------------------
\echo '### 2. The real ai.* inventory, from pg_proc ###'
-- -----------------------------------------------------------------------------
-- Every overload, with its actual argument list. This is the source of truth for
-- what Task 6 can demonstrate — and note ai.if in particular, which has BOTH a
-- (prompt, model_id) overload and a (prompt, embedding) proxy overload. Passing
-- all three arguments produces:
--    ERROR: function ai.if(text, vector, unknown) does not exist
-- which is a confusing message for what is really "you mixed the two forms".
SELECT p.proname,
       pg_get_function_identity_arguments(p.oid) AS args,
       pg_get_function_result(p.oid)             AS returns
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'ai'
ORDER BY p.proname, args;

-- -----------------------------------------------------------------------------
\echo '### 3. Registered models ###'
-- -----------------------------------------------------------------------------
-- Same view Lab 1 Task 5.2 introspects. model_request_url is the tell for which
-- backing service a model really uses — the semantic-ranker-* entries point at
-- discoveryengine.googleapis.com, which is WHY roles/aiplatform.user is not
-- enough for ai.rank() and why roles/discoveryengine.viewer exists in Terraform.
SELECT model_id, model_type, model_provider, model_request_url
FROM google_ml.model_info_view ORDER BY model_type, model_id;

-- -----------------------------------------------------------------------------
\echo '### 4. 🔴 PROXY MODELS ON PG 18 — the decisive test ###'
-- -----------------------------------------------------------------------------
-- The lab's story is a >100x cost claim. It only holds if the predicate is
-- LEARNABLE from profile text, because a proxy model is a logistic regression
-- over the embedding: it can only learn a boundary the embedding already
-- separates.
--
--   "Is this player a goalkeeper?"   -> should converge. Goalkeeper profiles use
--                                       different vocabulary from outfielders.
--   "Is this player underrated?"     -> will not. There is no such direction in
--                                       the embedding space, so the accuracy
--                                       check fails and every row falls back to
--                                       the LLM — which is the 100x claim in
--                                       reverse, live, in front of the room.
--
-- ⚠️ Training is IMPLICIT and ASYNCHRONOUS, triggered by PREPARE, and EXECUTE
-- must run on the SAME CONNECTION. There is no CREATE MODEL step and no
-- documented catalog to inspect the trained model in. Do not design a lab step
-- around showing students the model — verify it exists first.
--
-- ⚠️ Constraints, verbatim from the docs: ai.if() only, WHERE or SELECT only,
-- a single table alias, exactly one ai.if() in the query, no nesting in
-- subqueries.
--
-- ⚠️ AND THE DIMENSION QUESTION. Every published example uses VECTOR(768) from
-- text-embedding-005. Ours is VECTOR(3072) from gemini-embedding-001. No doc
-- states a cap, but 3072 is 4x the feature width on the same training sample,
-- which could plausibly push the accuracy check into permanent fallback. If it
-- does, gemini-embedding-001 supports MRL truncation to 768 and Task 6 gets a
-- second embedding column. THAT WOULD BE A TERRAFORM AND TASK-0 CHANGE, so it
-- needs to be known now, not during the build session.

\echo '--- 4a. baseline: the LLM path, timed, on a small slice ---'
\timing on
SELECT count(*) FROM (
  SELECT player_id FROM players
  WHERE profile_text IS NOT NULL
  LIMIT 200
) s;

\echo '--- 4b. the learnable predicate, proxy form ---'
PREPARE gk_proxy AS
SELECT p.player_id, p.name
FROM players p
WHERE ai.if('Is this player a goalkeeper? Profile: ' || p.profile_text,
            p.profile_embedding)
LIMIT 25;

\echo '>>> PREPARE returning cleanly does NOT mean training succeeded — it is'
\echo '>>> asynchronous. The verdict is what EXECUTE does next, ON THIS CONNECTION.'

EXECUTE gk_proxy;

\echo '>>> WATCH FOR THIS WARNING:'
\echo '>>>   "Reduced performance expected. Optimized AI function is not available"'
\echo '>>> That is the fallback-to-LLM signal and it is the ONLY observability'
\echo '>>> there is — there is no per-row indication of which rows fell back.'
\echo '>>> If it fires on the goalkeeper predicate, the feature is not usable'
\echo '>>> here and Task 6 must be rescoped. Record the exact text either way.'

\echo '--- 4c. the UNLEARNABLE predicate, as a deliberate contrast ---'
\echo '--- (this is also a candidate teaching moment: show the honest limit) ---'
PREPARE underrated_proxy AS
SELECT p.player_id, p.name
FROM players p
WHERE ai.if('Is this player underrated relative to their market value? Profile: ' || p.profile_text,
            p.profile_embedding)
LIMIT 25;
EXECUTE underrated_proxy;

\echo '--- 4d. the sibling feature, for the one contrasting sentence Task 6 owes ---'
\echo '>>> enable_ai_function_acceleration is documented PG 17 ONLY, covers ai.if'
\echo '>>> (WHERE only) and ai.rank (ORDER BY only), and needs NO embeddings.'
\echo '>>> Proxy models are ai.if-only but work in SELECT and need embeddings.'
SELECT name, setting FROM pg_settings
WHERE name = 'google_ml_integration.enable_ai_function_acceleration';
\echo '>>> If that returns zero rows on PG 18, the flag is genuinely absent here'
\echo '>>> and the contrast sentence should say so rather than implying a choice.'

-- -----------------------------------------------------------------------------
\echo '### 5. The rest of the ai.* family Task 6 walks ###'
-- -----------------------------------------------------------------------------
-- Run each against ONE row. The point of Task 6 is breadth, not volume, and a
-- family walk over 13,439 rows is a bill, not a lesson.
SELECT ai.generate('In one sentence, what kind of player is this? ' || profile_text) AS generated
FROM players WHERE profile_text IS NOT NULL LIMIT 1;

SELECT ai.summarize(prompt => profile_text) AS summary
FROM players WHERE profile_text IS NOT NULL LIMIT 1;

SELECT ai.analyze_sentiment(prompt => profile_text) AS sentiment
FROM players WHERE profile_text IS NOT NULL LIMIT 1;

\echo '>>> Any of the three above failing with "function does not exist" means the'
\echo '>>> extension is below its floor (1.5.2 / 1.5.7) or'
\echo '>>> enable_preview_ai_functions is off. Both are Terraform-side fixes.'

-- -----------------------------------------------------------------------------
\echo '### 6. Task 2 and Task 4 ammunition: prove the ambiguity ###'
-- -----------------------------------------------------------------------------
-- Tasks 2 and 4 may not assert what the LLM produces. The fix is to put the
-- ambiguity in the QUESTION, and this is the arithmetic that makes "How many
-- goals has Paulinho scored?" untrustworthy no matter what SQL comes back.
-- These numbers are BM25-style deterministic facts about the corpus, so unlike
-- anything vector-derived they are safe to print in lab prose.
SELECT count(*) AS paulinho_rows FROM players WHERE name ILIKE '%Paulinho%';
SELECT player_id, name, last_season FROM players WHERE name ILIKE '%Paulinho%' ORDER BY player_id;

SELECT count(*) AS duplicated_names, sum(c) AS rows_involved FROM (
  SELECT name, count(*) AS c FROM players GROUP BY name HAVING count(*) > 1
) d;
\echo '>>> Expect 937 duplicated names across 2,261 rows (P-30). If these differ,'
\echo '>>> the corpus moved and Task 2 needs its numbers re-derived.'

\timing off
\echo '### done — record every VERDICT and every warning text ###'
