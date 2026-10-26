#!/usr/bin/env python3
"""One-time redirect-only repair. Back up first, then run on a copy before live data.

Usage: python3 Scripts/merge-spotify-identity-keys.py DATABASE --report REPORT.json
No schema changes, Track updates, asset moves or deletions.
"""
import argparse
import hashlib
import json
import sqlite3
import time
from pathlib import Path
from urllib.parse import urlparse


def spotify_id(value):
    value = (value or "").strip().lower()
    if value.startswith("spotify:track:"):
        value = value[len("spotify:track:"):]
    elif value.startswith(("https://open.spotify.com/", "http://open.spotify.com/")):
        parts = urlparse(value).path.strip("/").split("/")
        value = parts[1] if len(parts) == 2 and parts[0] == "track" else ""
    return value if len(value) == 22 and value.isascii() and value.isalnum() else None


def fingerprints(db):
    # The two identity tables are the only permitted changes. sqlite_sequence
    # advances naturally when audit rows are appended.
    result = {}
    for (name,) in db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"):
        if name in ("track_identity_redirects", "track_identity_merge_audit"):
            continue
        digest = hashlib.sha256()
        quoted = '"' + name.replace('"', '""') + '"'
        for row in db.execute("SELECT * FROM " + quoted + " ORDER BY rowid"):
            digest.update(repr(tuple(row)).encode())
        result[name] = digest.hexdigest()
    return result


def merge(db):
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys=ON")
    with db:
        db.execute("BEGIN IMMEDIATE")
        before = fingerprints(db)
        tracks = {r["stable_key"]: r for r in db.execute("""
            SELECT t.*, EXISTS (
                SELECT 1 FROM lyrics_versions v WHERE v.track_stable_key=t.stable_key
                AND v.is_preferred=1 AND NOT EXISTS (
                    SELECT 1 FROM lyrics_selection_revocations r WHERE r.track_stable_key=t.stable_key
                )
            ) AS selected FROM tracks t
        """)}
        redirects = dict(db.execute("SELECT source_stable_key, canonical_stable_key FROM track_identity_redirects"))
        original_redirects = dict(redirects)
        original_audits = [tuple(r) for r in db.execute("SELECT * FROM track_identity_merge_audit ORDER BY id")]
        groups = {}
        for row in tracks.values():
            identity = spotify_id(row["spotify_id"]) or spotify_id(row["spotify_uri"])
            if identity:
                groups.setdefault(identity, []).append(row)

        def resolve(key):
            seen = set()
            while key in redirects:
                if key in seen:
                    raise ValueError("Redirect cycle: " + key)
                seen.add(key)
                key = redirects[key]
            return key

        report = []
        for identity, rows in sorted(groups.items()):
            if len(rows) < 2:
                continue
            chosen = min(rows, key=lambda r: (-r["selected"], r["created_at"], r["stable_key"]))
            target = resolve(chosen["stable_key"])
            added = []
            for row in rows:
                source = resolve(row["stable_key"])
                if source == target:
                    continue
                metadata = tracks[source]
                now = time.time()
                db.execute("""INSERT INTO track_identity_redirects VALUES (
                    ?, ?, 'same Spotify track ID', 'spotifyTrackIDExact', 'spotify-id-one-song-v1', ?
                )""", (source, target, now))
                db.execute("""INSERT INTO track_identity_merge_audit (
                    migration_id, source_stable_key, canonical_stable_key,
                    source_spotify_id, source_spotify_uri, source_isrc, source_title,
                    source_artist_display, source_album, source_duration, evidence, action, created_at
                ) VALUES ('spotify-id-one-song-v1', ?, ?, ?, ?, ?, ?, ?, ?, ?,
                          'spotifyTrackIDExact', 'redirect-only', ?)""",
                    (source, target, metadata["spotify_id"], metadata["spotify_uri"], metadata["isrc"],
                     metadata["title"], metadata["artist_display"], metadata["album"], metadata["duration"], now))
                redirects[source] = target
                added.append(source)
            report.append(dict(spotify_id=identity, title=chosen["title"], artist=chosen["artist_display"],
                               canonical_key=target, selected=bool(chosen["selected"]), added_sources=added))
        assert before == fingerprints(db), "An asset table changed; transaction rolled back"
        current_redirects = dict(db.execute("SELECT source_stable_key, canonical_stable_key FROM track_identity_redirects"))
        assert all(current_redirects[k] == v for k, v in original_redirects.items())
        audits = [tuple(r) for r in db.execute("SELECT * FROM track_identity_merge_audit ORDER BY id")]
        assert audits[:len(original_audits)] == original_audits
        assert len(audits) - len(original_audits) == sum(len(r["added_sources"]) for r in report)
        for key in redirects:
            assert resolve(key) in tracks
    return dict(groups_merged=sum(bool(r["added_sources"]) for r in report),
                redirects_added=sum(len(r["added_sources"]) for r in report),
                asset_tables_unchanged=True, songs=report)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("database", type=Path)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    with sqlite3.connect(args.database.resolve().as_uri() + "?mode=rw", uri=True) as connection:
        result = merge(connection)
    args.report.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result, ensure_ascii=False, indent=2))
