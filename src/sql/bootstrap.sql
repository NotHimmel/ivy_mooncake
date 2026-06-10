CREATE SCHEMA mooncake;

SELECT duckdb.install_extension('mooncake', 'community');

-- DROP EXTENSION cleanup watcher.
--
-- A member sql_drop trigger does NOT fire for the command that drops its own
-- extension. So this trigger is created and then DISOWNED via
-- ALTER EXTENSION ... DROP, making it a non-member that survives — and fires
-- on — DROP EXTENSION pg_mooncake. It lives in `public` because the `mooncake`
-- schema is removed during the same drop.
CREATE FUNCTION public.mooncake_extension_drop_cleanup() RETURNS event_trigger
LANGUAGE plpgsql AS $mooncake_drop_cleanup$
DECLARE
    is_mooncake_drop boolean := false;
    slot record;
BEGIN
    -- Act only when pg_mooncake itself is among the dropped objects.
    SELECT true INTO is_mooncake_drop
    FROM pg_event_trigger_dropped_objects()
    WHERE object_type = 'extension' AND object_name = 'pg_mooncake'
    LIMIT 1;

    IF NOT is_mooncake_drop THEN
        RETURN;
    END IF;

    -- Drop moonlink replication slots left behind in the current database.
    -- The active holder (if any) is the moonlink walsender; terminate it
    -- first since pg_drop_replication_slot refuses an active slot.
    FOR slot IN
        SELECT slot_name, active_pid
        FROM pg_replication_slots
        WHERE slot_name LIKE 'moonlink_slot_%'
          AND database = current_database()
    LOOP
        BEGIN
            IF slot.active_pid IS NOT NULL THEN
                PERFORM pg_terminate_backend(slot.active_pid);
            END IF;
            PERFORM pg_drop_replication_slot(slot.slot_name);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'pg_mooncake cleanup: failed to drop replication slot %: %',
                slot.slot_name, SQLERRM;
        END;
    END LOOP;

    -- Drop the moonlink publication if it still exists.
    BEGIN
        DROP PUBLICATION IF EXISTS moonlink_pub;
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pg_mooncake cleanup: failed to drop publication moonlink_pub: %',
            SQLERRM;
    END;

    -- Self-remove: not extension members, so they must clean themselves up.
    BEGIN
        DROP EVENT TRIGGER IF EXISTS mooncake_extension_drop_trigger;
        DROP FUNCTION IF EXISTS public.mooncake_extension_drop_cleanup();
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'pg_mooncake cleanup: failed to self-remove drop trigger: %',
            SQLERRM;
    END;
END;
$mooncake_drop_cleanup$;

CREATE EVENT TRIGGER mooncake_extension_drop_trigger ON sql_drop
    EXECUTE FUNCTION public.mooncake_extension_drop_cleanup();

-- Disown so the trigger/function survive and fire on DROP EXTENSION.
-- Legal mid-CREATE-EXTENSION (the extension catalog row already exists).
ALTER EXTENSION pg_mooncake DROP EVENT TRIGGER mooncake_extension_drop_trigger;
ALTER EXTENSION pg_mooncake DROP FUNCTION public.mooncake_extension_drop_cleanup();
