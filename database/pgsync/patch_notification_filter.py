"""Avoid a per-row SQL JSON join when checking configured search columns."""
from hashlib import sha256
from importlib.metadata import distribution
from pathlib import Path

path = Path(distribution('pgsync').locate_file('pgsync/trigger.py'))
source = path.read_text()
if sha256(source.rstrip('\n').encode()).hexdigest() != '03859e0cf542bc957fa2134d9f6b9eb252902eadb5d21c2ee3482e2a065dd28c':
    raise RuntimeError('PGSync trigger template changed; review the column filter patch')
original = '                SELECT EXISTS (\n                    SELECT 1\n                    FROM JSONB_EACH(TO_JSONB(NEW.*)) n\n                    JOIN JSONB_EACH(TO_JSONB(OLD.*)) o USING (key)\n                    WHERE n.key = ANY(_columns)\n                    AND n.value IS DISTINCT FROM o.value\n                )\n                INTO _changed;'
replacement = '                -- Compare only configured search columns without expanding and\n                -- joining every key for each high-volume observation update.\n                _old_values := TO_JSONB(OLD.*);\n                _new_values := TO_JSONB(NEW.*);\n                _changed := FALSE;\n                FOREACH _column IN ARRAY _columns LOOP\n                    IF _new_values -> _column IS DISTINCT FROM _old_values -> _column THEN\n                        _changed := TRUE;\n                        EXIT;\n                    END IF;\n                END LOOP;'
if source.count(original) != 1 or source.count('  _changed BOOLEAN;') != 1:
    raise RuntimeError('Expected one configured-column comparison')
source = source.replace(original, replacement, 1)
source = source.replace('  _changed BOOLEAN;', '  _changed BOOLEAN;\n  _column TEXT;\n  _old_values JSONB;\n  _new_values JSONB;', 1)
compile(source, str(path), 'exec')
path.write_text(source)
print('Applied reviewed configured-column notification filter')
