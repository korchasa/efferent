-- What the service is allowed to know: when each event happened and what kind
-- it is. No values, no ids, no sources — those stay inside the sealed blob that
-- this database only points at.
--
-- One row per event. `seq_from`/`seq_to` name the object holding it, so a query
-- answers with the handful of batches worth downloading rather than with data.

CREATE TABLE IF NOT EXISTS events (
    bucket   TEXT    NOT NULL,
    seq      INTEGER NOT NULL,
    type     TEXT    NOT NULL,
    metric   TEXT,
    -- Whole seconds since 1970. A deletion names an event without describing
    -- one, so it has no interval and both columns stay null.
    start    INTEGER,
    end      INTEGER,
    seq_from INTEGER NOT NULL,
    seq_to   INTEGER NOT NULL,
    -- A device that did not hear the answer sends the same range again. The
    -- object is not rewritten, and neither are these rows.
    PRIMARY KEY (bucket, seq)
);

-- The two questions worth asking: what happened in this stretch of time, and
-- what happened in it of one kind. Both start with the bucket, because every
-- query is inside one archive and nothing ever spans two.
CREATE INDEX IF NOT EXISTS events_by_time ON events (bucket, start);
CREATE INDEX IF NOT EXISTS events_by_metric ON events (bucket, metric, start);
