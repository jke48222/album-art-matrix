/* Forget stored fingerprints without keeping a copy of the sound.
 * This helper links Olaf's AGPL-3.0-or-later database implementation and
 * is distributed under the same license. The install script keeps the
 * complete pinned Olaf source and license beside the resulting binaries.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdbool.h>
#include "olaf_db.h"

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "[teach] usage: olaf-forget db-folder fingerprint-csv numeric-id\n");
        return 2;
    }
    FILE *file = fopen(argv[2], "r");
    if (!file) return 3;
    char *end;
    unsigned long parsed = strtoul(argv[3], &end, 10);
    if (*end || parsed > UINT32_MAX) { fclose(file); return 2; }
    uint32_t id = (uint32_t) parsed;
    Olaf_DB *db = olaf_db_new(argv[1], false);
    uint64_t keys[1024], values[1024];
    size_t count = 0;
    char line[2048];
    while (fgets(line, sizeof(line), file)) {
        uint64_t hash, stamp;
        if (sscanf(line, "%" SCNu64 ", %" SCNu64, &hash, &stamp) != 2) continue;
        keys[count] = hash;
        values[count++] = (stamp << 32) | id;
        if (count == 1024) { olaf_db_delete(db, keys, values, count); count = 0; }
    }
    if (count) olaf_db_delete(db, keys, values, count);
    olaf_db_delete_meta_data(db, &id);
    olaf_db_destroy(db);
    fclose(file);
    return 0;
}
