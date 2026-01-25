-- Migration: Initial Schema
-- Safe to re-run (uses IF NOT EXISTS)

-- ============================================================================
-- Transactions
-- ============================================================================

CREATE TABLE IF NOT EXISTS transactions (
  tx_id INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at TEXT DEFAULT (datetime('now'))
) STRICT;

CREATE INDEX IF NOT EXISTS idx_tx_created
  ON transactions(created_at);

-- ============================================================================
-- EVA - Core triple store
-- ============================================================================

CREATE TABLE IF NOT EXISTS eva (
  entity_id INTEGER NOT NULL,
  attribute INTEGER NOT NULL,
  instance INTEGER NOT NULL,

  -- Typed value columns (only one should be non-NULL per row)
  value_type INTEGER NOT NULL,         -- 0=int, 1=real, 2=text, 3=blob
  value_int INTEGER,
  value_real REAL,
  value_text TEXT,
  value_blob BLOB,

  asserted_at INTEGER NOT NULL,        -- tx_id when asserted
  retracted_at INTEGER,                -- tx_id when retracted, NULL if current

  PRIMARY KEY (entity_id, attribute, instance, asserted_at),

  CHECK (entity_id >= 0),
  CHECK (attribute >= 0),
  CHECK (instance >= 0),
  CHECK (value_type >= 0 AND value_type <= 3),

  FOREIGN KEY (asserted_at) REFERENCES transactions(tx_id),
  FOREIGN KEY (retracted_at) REFERENCES transactions(tx_id)
) STRICT;

-- ============================================================================
-- Auto-Retraction Trigger
-- ============================================================================

-- Automatically retract previous assertions when new value is asserted
CREATE TRIGGER IF NOT EXISTS auto_retract_previous
AFTER INSERT ON eva
WHEN NEW.retracted_at IS NULL
BEGIN
  UPDATE eva
  SET retracted_at = NEW.asserted_at
  WHERE entity_id = NEW.entity_id
    AND attribute = NEW.attribute
    AND instance = NEW.instance
    AND asserted_at < NEW.asserted_at
    AND retracted_at IS NULL;
END;

-- ============================================================================
-- Indexes for common query patterns
-- ============================================================================

-- Current state only (most common queries)
CREATE INDEX IF NOT EXISTS idx_eva_current_entity
  ON eva(entity_id, attribute, instance)
  WHERE retracted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_eva_current_attribute
  ON eva(attribute, entity_id)
  WHERE retracted_at IS NULL;

-- Value lookups for current state (VAET pattern)
CREATE INDEX IF NOT EXISTS idx_eva_current_value_int
  ON eva(attribute, value_int, entity_id)
  WHERE retracted_at IS NULL AND value_type = 0;

CREATE INDEX IF NOT EXISTS idx_eva_current_value_real
  ON eva(attribute, value_real, entity_id)
  WHERE retracted_at IS NULL AND value_type = 1;

CREATE INDEX IF NOT EXISTS idx_eva_current_value_text
  ON eva(attribute, value_text, entity_id)
  WHERE retracted_at IS NULL AND value_type = 2;

-- Transaction history (includes retracted entries)
CREATE INDEX IF NOT EXISTS idx_eva_asserted_at
  ON eva(asserted_at, entity_id, attribute);

CREATE INDEX IF NOT EXISTS idx_eva_retracted_at
  ON eva(retracted_at, entity_id, attribute)
  WHERE retracted_at IS NOT NULL;

-- Special index for entity 0 (attribute registry)
CREATE INDEX IF NOT EXISTS idx_eva_attr_registry
  ON eva(attribute, instance)
  WHERE entity_id = 0 AND retracted_at IS NULL;

-- ============================================================================
-- Bootstrap Transaction
-- ============================================================================

-- Create the initial bootstrap transaction
INSERT OR IGNORE INTO transactions (tx_id, created_at)
VALUES (1, datetime('now'));

-- ============================================================================
-- Bootstrap Attribute Definitions (Entity 0)
-- ============================================================================
-- Convention for instance values on entity 0:
--   instance 0 = name (text)
--   instance 1 = value_type (int: 0=int, 1=real, 2=text, 3=blob)
--   instance 2 = cardinality (int: 0=single, 1=multi) - skip if 0 (default)
--   instance 3 = unique_value (int: 0=no, 1=yes) - skip if 0 (default)
--   instance 4 = doc (text)

-- Attribute 0: :attr/name
INSERT OR IGNORE INTO eva VALUES (0, 0, 0, 2, NULL, NULL, ':attr/name', NULL, 1, NULL);
INSERT OR IGNORE INTO eva VALUES (0, 0, 1, 0, 2, NULL, NULL, NULL, 1, NULL);
INSERT OR IGNORE INTO eva VALUES (0, 0, 3, 0, 1, NULL, NULL, NULL, 1, NULL);
INSERT OR IGNORE INTO eva VALUES (0, 0, 4, 2, NULL, NULL, 'The name of an attribute', NULL, 1, NULL);

-- Attribute 1: :attr/value_type
INSERT OR IGNORE INTO eva VALUES (0, 1, 0, 2, NULL, NULL, ':attr/value_type', NULL, 1, NULL);
INSERT OR IGNORE INTO eva VALUES (0, 1, 1, 0, 0, NULL, NULL, NULL, 1, NULL);
INSERT OR IGNORE INTO eva VALUES (0, 1, 4, 2, NULL, NULL, 'Expected value type (0=int, 1=real, 2=text, 3=blob)', NULL, 1, NULL);

-- Attribute 2: :attr/cardinality
INSERT OR IGNORE INTO eva VALUES (0, 2, 0, 2, NULL, NULL, ':attr/cardinality', NULL, 1, NULL);
INSERT OR IGNORE INTO eva VALUES (0, 2, 1, 0, 0, NULL, NULL, NULL, 1, NULL);
INSERT OR IGNORE INTO eva VALUES (0, 2, 4, 2, NULL, NULL, 'Attribute cardinality (0=single, 1=multi)', NULL, 1, NULL);

-- Attribute 3: :attr/unique
INSERT OR IGNORE INTO eva VALUES (0, 3, 0, 2, NULL, NULL, ':attr/unique', NULL, 1, NULL);
INSERT OR IGNORE INTO eva VALUES (0, 3, 1, 0, 0, NULL, NULL, NULL, 1, NULL);
INSERT OR IGNORE INTO eva VALUES (0, 3, 4, 2, NULL, NULL, 'Whether attribute values must be unique across all entities (0=no, 1=yes)', NULL, 1, NULL);

-- Attribute 4: :attr/doc
INSERT OR IGNORE INTO eva VALUES (0, 4, 0, 2, NULL, NULL, ':attr/doc', NULL, 1, NULL);
INSERT OR IGNORE INTO eva VALUES (0, 4, 1, 0, 2, NULL, NULL, NULL, 1, NULL);
INSERT OR IGNORE INTO eva VALUES (0, 4, 4, 2, NULL, NULL, 'Documentation string for an attribute', NULL, 1, NULL);

-- ============================================================================
-- Schema Reference Attribute
-- ============================================================================

-- Attribute 5: :entity/schema
-- References the schema entity_id for this entity
INSERT OR IGNORE INTO eva VALUES (0, 5, 0, 2, NULL, NULL, ':entity/schema', NULL, 1, NULL);
INSERT OR IGNORE INTO eva VALUES (0, 5, 1, 0, 0, NULL, NULL, NULL, 1, NULL);  -- int
INSERT OR IGNORE INTO eva VALUES (0, 5, 2, 0, 1, NULL, NULL, NULL, 1, NULL);  -- multi-cardinality
INSERT OR IGNORE INTO eva VALUES (0, 5, 4, 2, NULL, NULL, 'Schema entity_id for this entity', NULL, 1, NULL);

-- ============================================================================
-- Schema Metadata Attributes (11-13)
-- ============================================================================

-- Attribute 11: :schema/type
INSERT OR IGNORE INTO eva VALUES (0, 11, 0, 2, NULL, NULL, ':schema/type', NULL, 1, NULL);
INSERT OR IGNORE INTO eva VALUES (0, 11, 1, 0, 2, NULL, NULL, NULL, 1, NULL);  -- text
INSERT OR IGNORE INTO eva VALUES (0, 11, 3, 0, 1, NULL, NULL, NULL, 1, NULL);  -- unique
INSERT OR IGNORE INTO eva VALUES (0, 11, 4, 2, NULL, NULL, 'Human-readable type name (must be unique)', NULL, 1, NULL);

-- Attribute 12: :schema/version
INSERT OR IGNORE INTO eva VALUES (0, 12, 0, 2, NULL, NULL, ':schema/version', NULL, 1, NULL);
INSERT OR IGNORE INTO eva VALUES (0, 12, 1, 0, 2, NULL, NULL, NULL, 1, NULL);  -- text
INSERT OR IGNORE INTO eva VALUES (0, 12, 4, 2, NULL, NULL, 'Semantic version string', NULL, 1, NULL);

-- Attribute 13: :schema/doc
INSERT OR IGNORE INTO eva VALUES (0, 13, 0, 2, NULL, NULL, ':schema/doc', NULL, 1, NULL);
INSERT OR IGNORE INTO eva VALUES (0, 13, 1, 0, 2, NULL, NULL, NULL, 1, NULL);  -- text
INSERT OR IGNORE INTO eva VALUES (0, 13, 4, 2, NULL, NULL, 'Schema documentation', NULL, 1, NULL);

-- ============================================================================
-- Schema Attribute References (31-32)
-- ============================================================================

-- Attribute 31: :schema/attr
-- Attribute IDs that are part of this schema (multi-cardinality)
INSERT OR IGNORE INTO eva VALUES (0, 31, 0, 2, NULL, NULL, ':schema/attr', NULL, 1, NULL);
INSERT OR IGNORE INTO eva VALUES (0, 31, 1, 0, 0, NULL, NULL, NULL, 1, NULL);  -- int
INSERT OR IGNORE INTO eva VALUES (0, 31, 2, 0, 1, NULL, NULL, NULL, 1, NULL);  -- multi-cardinality
INSERT OR IGNORE INTO eva VALUES (0, 31, 4, 2, NULL, NULL, 'Attribute IDs in this schema (instance N = Nth attribute)', NULL, 1, NULL);

-- Attribute 32: :schema/attr/required
-- Whether each attribute is required (aligned by instance with :schema/attr)
INSERT OR IGNORE INTO eva VALUES (0, 32, 0, 2, NULL, NULL, ':schema/attr/required', NULL, 1, NULL);
INSERT OR IGNORE INTO eva VALUES (0, 32, 1, 0, 0, NULL, NULL, NULL, 1, NULL);  -- int
INSERT OR IGNORE INTO eva VALUES (0, 32, 2, 0, 1, NULL, NULL, NULL, 1, NULL);  -- multi-cardinality
INSERT OR IGNORE INTO eva VALUES (0, 32, 4, 2, NULL, NULL, 'Required flag for each attribute (0=optional, 1=required)', NULL, 1, NULL);

-- ============================================================================
-- Materialized View for Current State
-- ============================================================================

-- Simple view of current state - just filter on retracted_at IS NULL
CREATE VIEW IF NOT EXISTS eva_current AS
  SELECT
    entity_id,
    attribute,
    instance,
    value_type,
    value_int,
    value_real,
    value_text,
    value_blob,
    asserted_at
  FROM eva
  WHERE retracted_at IS NULL;

-- ============================================================================
-- Helper View: Attribute Registry
-- ============================================================================

-- Convenience view to see all defined attributes
CREATE VIEW IF NOT EXISTS attributes AS
  SELECT
    a.attribute as attribute_id,
    MAX(CASE WHEN a.instance = 0 THEN a.value_text END) as name,
    MAX(CASE WHEN a.instance = 1 THEN a.value_int END) as value_type,
    MAX(CASE WHEN a.instance = 2 THEN a.value_int END) as cardinality,
    MAX(CASE WHEN a.instance = 3 THEN a.value_int END) as unique_value,
    MAX(CASE WHEN a.instance = 4 THEN a.value_text END) as doc
  FROM eva_current a
  WHERE a.entity_id = 0
  GROUP BY a.attribute;

-- ============================================================================
-- Helper Views for Schemas
-- ============================================================================

-- View: All schemas with metadata
CREATE VIEW IF NOT EXISTS schemas AS
SELECT
  e.entity_id,
  MAX(CASE WHEN e.attribute = 11 THEN e.value_text END) as type,
  MAX(CASE WHEN e.attribute = 12 THEN e.value_text END) as version,
  MAX(CASE WHEN e.attribute = 13 THEN e.value_text END) as doc,
  -- Computed display name
  MAX(CASE WHEN e.attribute = 11 THEN e.value_text END) ||
  COALESCE('@' || MAX(CASE WHEN e.attribute = 12 THEN e.value_text END), '') as display_name
FROM eva_current e
WHERE e.attribute BETWEEN 11 AND 13
GROUP BY e.entity_id;

-- View: Schema attributes
CREATE VIEW IF NOT EXISTS schema_attrs AS
SELECT
  e.entity_id as schema_id,
  s.type as schema_type,
  s.version as schema_version,
  s.display_name as schema_name,
  e.instance as attr_index,
  e1.value_int as attr_id,
  a.name as attr_name,
  e2.value_int as required
FROM eva_current e1
LEFT JOIN eva_current e2
  ON e1.entity_id = e2.entity_id
  AND e1.instance = e2.instance
  AND e2.attribute = 32
JOIN schemas s ON e1.entity_id = s.entity_id
LEFT JOIN attributes a ON e1.value_int = a.attribute_id
WHERE e1.attribute = 31
ORDER BY e1.entity_id, e1.instance;
