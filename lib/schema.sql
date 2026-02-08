-- Migration: Attributes table, simplified EVA
-- Safe to re-run (uses IF NOT EXISTS / OR IGNORE)

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
-- Attributes
-- ============================================================================

CREATE TABLE IF NOT EXISTS attributes (
  attribute_id INTEGER NOT NULL,
  name TEXT NOT NULL,
  value_type INTEGER NOT NULL DEFAULT 0,  -- semantic type (see below)
  cardinality INTEGER NOT NULL DEFAULT 0, -- 0=single, 1=multi
  unique_value INTEGER NOT NULL DEFAULT 0,
  doc TEXT,

  asserted_at INTEGER NOT NULL,        -- tx_id when asserted
  retracted_at INTEGER,                -- tx_id when retracted, NULL if current

  UNIQUE (attribute_id, asserted_at),

  CHECK (value_type BETWEEN 0 AND 6),
  CHECK (cardinality IN (0, 1)),
  CHECK (unique_value IN (0, 1)),
  CHECK (attribute_id >= 0),

  FOREIGN KEY (asserted_at) REFERENCES transactions(tx_id),
  FOREIGN KEY (retracted_at) REFERENCES transactions(tx_id)
) STRICT;

-- Ensure attribute names are unique in current state
CREATE UNIQUE INDEX IF NOT EXISTS idx_attr_unique_name
  ON attributes(name)
  WHERE retracted_at IS NULL;

-- value_type reference:
--   0 = string  (TEXT)
--   1 = number  (INTEGER or REAL)
--   2 = boolean (INTEGER 0/1)
--   3 = datetime (TEXT ISO 8601)
--   4 = ref     (INTEGER entity ID)
--   5 = json    (TEXT)
--   6 = blob    (BLOB)

-- ============================================================================
-- Auto-Retraction Trigger for Attributes
-- ============================================================================

-- Automatically retract previous attribute definitions when a new version is asserted.
-- Since all attribute changes are single-cardinality, any new entry overwrites old ones.
-- IMPORTANT: This must be a BEFORE trigger so retractions happen before uniqueness checks.
CREATE TRIGGER IF NOT EXISTS auto_retract_previous_attr
BEFORE INSERT ON attributes
WHEN NEW.retracted_at IS NULL
BEGIN
  UPDATE attributes
  SET retracted_at = NEW.asserted_at
  WHERE attribute_id = NEW.attribute_id
    AND asserted_at < NEW.asserted_at
    AND retracted_at IS NULL;
END;

-- ============================================================================
-- EVA - Core triple store
-- ============================================================================

CREATE TABLE IF NOT EXISTS eva (
  entity_id INTEGER NOT NULL,
  attribute INTEGER NOT NULL,
  value ANY NOT NULL,

  asserted_at INTEGER NOT NULL,        -- tx_id when asserted
  retracted_at INTEGER,                -- tx_id when retracted, NULL if current

  UNIQUE (entity_id, attribute, value, asserted_at),

  CHECK (entity_id >= 0),
  CHECK (attribute >= 0),

  FOREIGN KEY (attribute) REFERENCES attributes(attribute_id),
  FOREIGN KEY (asserted_at) REFERENCES transactions(tx_id),
  FOREIGN KEY (retracted_at) REFERENCES transactions(tx_id)
) STRICT;

-- ============================================================================
-- Auto-Retraction Trigger
-- ============================================================================

-- Automatically retract previous assertions for single-cardinality attributes.
-- Multi-cardinality values accumulate; must be explicitly retracted.
CREATE TRIGGER IF NOT EXISTS auto_retract_previous
AFTER INSERT ON eva
WHEN NEW.retracted_at IS NULL
  AND (SELECT cardinality FROM attributes WHERE attribute_id = NEW.attribute AND retracted_at IS NULL) = 0
BEGIN
  UPDATE eva
  SET retracted_at = NEW.asserted_at
  WHERE entity_id = NEW.entity_id
    AND attribute = NEW.attribute
    AND asserted_at < NEW.asserted_at
    AND retracted_at IS NULL;
END;

-- ============================================================================
-- Indexes
-- ============================================================================

-- Attributes: Current state by attribute_id
CREATE INDEX IF NOT EXISTS idx_attr_current
  ON attributes(attribute_id)
  WHERE retracted_at IS NULL;

-- Attributes: Current state by name
CREATE INDEX IF NOT EXISTS idx_attr_current_name
  ON attributes(name)
  WHERE retracted_at IS NULL;

-- Attributes: Transaction history
CREATE INDEX IF NOT EXISTS idx_attr_asserted_at
  ON attributes(asserted_at, attribute_id);

CREATE INDEX IF NOT EXISTS idx_attr_retracted_at
  ON attributes(retracted_at, attribute_id)
  WHERE retracted_at IS NOT NULL;

-- Current state by entity
CREATE INDEX IF NOT EXISTS idx_eva_current_entity
  ON eva(entity_id, attribute)
  WHERE retracted_at IS NULL;

-- Current state by attribute
CREATE INDEX IF NOT EXISTS idx_eva_current_attribute
  ON eva(attribute, entity_id)
  WHERE retracted_at IS NULL;

-- Value lookups for current state (VAET pattern)
CREATE INDEX IF NOT EXISTS idx_eva_current_value
  ON eva(attribute, value, entity_id)
  WHERE retracted_at IS NULL;

-- Transaction history
CREATE INDEX IF NOT EXISTS idx_eva_asserted_at
  ON eva(asserted_at, entity_id, attribute);

CREATE INDEX IF NOT EXISTS idx_eva_retracted_at
  ON eva(retracted_at, entity_id, attribute)
  WHERE retracted_at IS NOT NULL;

-- ============================================================================
-- Bootstrap Transaction
-- ============================================================================

INSERT OR IGNORE INTO transactions (tx_id, created_at)
VALUES (1, datetime('now'));

-- ============================================================================
-- Bootstrap Attribute Definitions
-- ============================================================================

-- (attribute_id, name, value_type, cardinality, unique_value, doc, asserted_at, retracted_at)
INSERT OR IGNORE INTO attributes VALUES (5,  ':entity/schema',         4, 1, 0, 'Schema entity_id for this entity', 1, NULL);
INSERT OR IGNORE INTO attributes VALUES (11, ':schema/type',           0, 0, 1, 'Human-readable type name (must be unique)', 1, NULL);
INSERT OR IGNORE INTO attributes VALUES (12, ':schema/version',        0, 0, 0, 'Semantic version string', 1, NULL);
INSERT OR IGNORE INTO attributes VALUES (13, ':schema/doc',            0, 0, 0, 'Schema documentation', 1, NULL);
INSERT OR IGNORE INTO attributes VALUES (31, ':schema/attr',           4, 1, 0, 'Attribute IDs in this schema', 1, NULL);
INSERT OR IGNORE INTO attributes VALUES (32, ':schema/attr/required',  4, 1, 0, 'Set of attr_ids that are required for this schema', 1, NULL);

INSERT OR IGNORE INTO attributes VALUES (6,  ':attr/of-schema',        4, 1, 0, 'Target schema(s) for ref values (anyOf constraint)', 1, NULL);

INSERT OR IGNORE INTO attributes VALUES (41, ':enum/value',            0, 0, 1, 'Enum member label (unique across all enums)', 1, NULL);
INSERT OR IGNORE INTO attributes VALUES (42, ':enum/ordinal',          1, 0, 0, 'Sort order within enum', 1, NULL);

-- ============================================================================
-- Views
-- ============================================================================

-- Current state of all attribute definitions
CREATE VIEW IF NOT EXISTS attributes_current AS
  SELECT
    attribute_id,
    name,
    value_type,
    cardinality,
    unique_value,
    doc,
    asserted_at
  FROM attributes
  WHERE retracted_at IS NULL;

-- Current state of all facts
CREATE VIEW IF NOT EXISTS eva_current AS
  SELECT
    entity_id,
    attribute,
    value,
    asserted_at
  FROM eva
  WHERE retracted_at IS NULL;

-- All schemas with metadata
CREATE VIEW IF NOT EXISTS schemas AS
SELECT
  e.entity_id,
  MAX(CASE WHEN e.attribute = 11 THEN e.value END) as type,
  MAX(CASE WHEN e.attribute = 12 THEN e.value END) as version,
  MAX(CASE WHEN e.attribute = 13 THEN e.value END) as doc,
  MAX(CASE WHEN e.attribute = 11 THEN e.value END) ||
  COALESCE('@' || MAX(CASE WHEN e.attribute = 12 THEN e.value END), '') as display_name
FROM eva_current e
WHERE e.attribute BETWEEN 11 AND 13
GROUP BY e.entity_id;

-- Schema attributes with required flags
CREATE VIEW IF NOT EXISTS schema_attrs AS
SELECT
  e1.entity_id as schema_id,
  s.type as schema_type,
  s.version as schema_version,
  s.display_name as schema_name,
  e1.value as attr_id,
  a.name as attr_name,
  CASE WHEN e2.value IS NOT NULL THEN 1 ELSE 0 END as required
FROM eva_current e1
JOIN schemas s ON e1.entity_id = s.entity_id
LEFT JOIN attributes_current a ON e1.value = a.attribute_id
LEFT JOIN eva_current e2
  ON e1.entity_id = e2.entity_id
  AND e2.attribute = 32
  AND e2.value = e1.value
WHERE e1.attribute = 31
ORDER BY e1.entity_id, e1.value;

-- Enum schemas with their members
CREATE VIEW IF NOT EXISTS enum_members AS
SELECT
  s.entity_id as enum_id,
  s.type as enum_type,
  m.entity_id as member_id,
  MAX(CASE WHEN m.attribute = 41 THEN m.value END) as value,
  MAX(CASE WHEN m.attribute = 42 THEN m.value END) as ordinal
FROM schemas s
JOIN eva_current membership
  ON membership.attribute = 5          -- :entity/schema
  AND membership.value = s.entity_id
JOIN eva_current m
  ON m.entity_id = membership.entity_id
  AND m.attribute IN (41, 42)          -- :enum/value, :enum/ordinal
GROUP BY s.entity_id, s.type, m.entity_id
ORDER BY s.entity_id, ordinal, value;
