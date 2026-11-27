-- +goose Up
ALTER TABLE artifact_versions
  ADD COLUMN IF NOT EXISTS word_count INT NOT NULL DEFAULT 0;

UPDATE artifact_versions v
SET word_count = COALESCE(
  array_length(
    regexp_split_to_array(
      NULLIF(
        btrim(
          regexp_replace(
            regexp_replace(v.body_md, '```.*?```', ' ', 'g'),
            '!\[\[[^\]]*\]\]',
            ' ',
            'g'
          )
        ),
        ''
      ),
      '\s+'
    ),
    1
  ),
  0
)
FROM artifacts a
WHERE a.id = v.artifact_id
  AND a.type <> 'mockup'
  AND v.body_md IS NOT NULL
  AND v.body_md <> ''
  AND v.word_count = 0;

-- +goose Down
ALTER TABLE artifact_versions
  DROP COLUMN IF EXISTS word_count;
