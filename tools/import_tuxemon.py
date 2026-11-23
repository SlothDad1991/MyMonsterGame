"""Import a set of Tuxemon monsters (art + data) into the game.
Usage: python3 import_tuxemon.py <tuxemon_checkout> <game_repo>
Art: Tuxemon project, mostly CC BY-SA 4.0 (see CREDITS.md)."""
import sys, os, re, json, glob, shutil, yaml

TUX, GAME = sys.argv[1], sys.argv[2]
M = os.path.join(TUX, "mods/tuxemon")

# Only monsters whose art has an explicit credit + licence in Tuxemon's ATTRIBUTIONS.md.
STARTERS = ["agnite", "dollfin", "anoleaf"]
LINES = {  # first stage : wild weight (0 = starters, never wild)
    "agnite": 0, "dollfin": 0, "anoleaf": 0,
    "cairfrey": 18, "vamporm": 18, "propellercat": 14, "pigabyte": 12, "axolightl": 10,
    "lambert": 10, "selket": 10, "sludgehog": 8, "cardiling": 8, "merlicun": 8,
    "noctula": 8, "tweesher": 6, "chillimp": 6, "eyenemy": 5, "wrougon": 4,
}
# our own evolution levels where Tuxemon uses items instead, or we stop a line early
EVO_OVERRIDE = {"dollfin": [[16, "bigfin"]], "bigfin": [[32, "sharpfin"]], "axolightl": []}
STAGE_MULT = {"basic": 1.0, "stage1": 1.25, "stage2": 1.5, "standalone": 1.2}

mons = {}
for f in glob.glob(f"{M}/db/monster/*.yaml"):
    d = yaml.safe_load(open(f))
    mons[d["slug"]] = d

def evos(s):
    if s in EVO_OVERRIDE:
        return EVO_OVERRIDE[s]
    return [[int(e["at_level"]), e["monster_slug"]] for e in (mons[s].get("evolutions") or [])
            if "at_level" in e and e.get("monster_slug") in mons]

def chain(s):
    out = [s]
    while True:
        ev = evos(out[-1])
        if not ev or ev[0][1] in out:
            return out
        out.append(ev[0][1])

# English names from the translation file
names = {}
po = open(f"{M}/l18n/en_US/LC_MESSAGES/base.po", encoding="utf-8").read()
for k, v in re.findall(r'msgid "([^"]+)"\nmsgstr "([^"]*)"', po):
    names[k] = v

shapes = {s["slug"]: s["attributes"] for s in yaml.safe_load(open(f"{M}/db/shape/shapes.yaml"))}

def cap(t): return t.capitalize()

chosen = []
for first in LINES:
    for s in chain(first):
        if s not in chosen:
            chosen.append(s)
print(len(chosen), "monsters")

techs = {}
def tech(slug):
    p = f"{M}/db/technique/{slug}.yaml"
    if not os.path.exists(p): return None
    t = yaml.safe_load(open(p))
    if t.get("sort") != "damage" or not t.get("power"): return None
    if not any(e.get("type") == "damage" for e in (t.get("effects") or [])): return None
    types = t.get("types") or ["normal"]
    return {"name": names.get(slug, slug.replace("_", " ").title()), "type": cap(types[0]),
            "power": max(20, min(110, int(round(float(t["power"]) * 25)))),
            "accuracy": max(70, min(100, int(round(float(t.get("accuracy", 1)) * 100))))}

out_mons, out_moves = {}, {"tackle": {"name": "Tackle", "type": "Normal", "power": 40, "accuracy": 100}}
for s in chosen:
    d = mons[s]
    a = shapes.get(d.get("shape"), {"hp": 6, "melee": 6, "ranged": 6, "armour": 6, "speed": 6})
    mult = STAGE_MULT.get(d.get("stage"), 1.0)
    learn = []
    for e in d.get("moveset") or []:
        if e.get("learning_method") == "fallback": continue
        t = e["technique"]
        if t not in out_moves:
            info = tech(t)
            if not info: continue
            out_moves[t] = info
        learn.append([int(e["level_learned"]), t])
    if not any(l <= 1 for l, _ in learn):
        learn.insert(0, [1, "tackle"])
    evo = [e for e in evos(s) if e[1] in chosen]
    out_mons[s] = {
        "name": names.get(s, s.title()),
        "types": [cap(t) for t in d.get("types", ["normal"])],
        "starter": s in STARTERS,
        "base": {"hp": int(a["hp"] * 10 * mult), "atk": int(max(a["melee"], a["ranged"]) * 10 * mult),
                 "def": int(a["armour"] * 10 * mult), "spd": int(a["speed"] * 10 * mult)},
        "catch_rate": int(min(255, float(d.get("catch_rate", 100)))),
        "wild_weight": LINES.get(s, 0),
        "moves": learn,
        "evolutions": evo,
        "sprite": f"res://art/monsters/{s}.png",
    }
    os.makedirs(f"{GAME}/art/monsters", exist_ok=True)
    shutil.copy(f"{M}/gfx/sprites/battle/{s}-sheet.png", f"{GAME}/art/monsters/{s}.png")

# type chart (only non-neutral matchups)
chart = {}
for f in glob.glob(f"{M}/db/element/*.yaml"):
    e = yaml.safe_load(open(f))
    row = {cap(t["against"]): float(t["multiplier"]) for t in e.get("types", []) if float(t["multiplier"]) != 1.0}
    chart[cap(e["slug"])] = row

json.dump(out_mons, open(f"{GAME}/data/monsters.json", "w"), indent=1)
json.dump(out_moves, open(f"{GAME}/data/moves.json", "w"), indent=1)
json.dump(chart, open(f"{GAME}/data/types.json", "w"), indent=1)

# credits: copy the matching entries from Tuxemon's ATTRIBUTIONS.md
attr = open(f"{TUX}/ATTRIBUTIONS.md", encoding="utf-8").read()
blocks = re.split(r"\n(?=\* \[)", attr)
lines = ["# Credits", "",
         "Monster art comes from the open-source [Tuxemon](https://github.com/Tuxemon/Tuxemon) project.",
         "Unless noted otherwise it is licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/);",
         "any changes we make to that art are shared under the same licence.", "",
         "Font: Press Start 2P by codeman38, SIL Open Font License (fonts/PressStart2P-OFL.txt).", "",
         "## Monsters", ""]
for s in chosen:
    nm = out_mons[s]["name"]
    hit = next((b.strip() for b in blocks if b.startswith(f'* ["{nm}"]')), None)
    lines.append(hit if hit else f'* "{nm}" from the Tuxemon project (see its ATTRIBUTIONS.md)')
    lines.append("")
open(f"{GAME}/CREDITS.md", "w", encoding="utf-8").write("\n".join(lines))
print("moves", len(out_moves), "types", sorted(chart))
missing = [s for s in chosen if not any(b.startswith(f'* ["{out_mons[s]["name"]}"]') for b in blocks)]
print("no credit entry:", missing)

# plain-text credits for the in-game CREDITS screen
def plain(block):
    t = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", block).replace("\n", " ").lstrip("* ").strip()
    t = re.sub(r"\s+", " ", t)
    return t
txt = ["MONSTER ART", "From the Tuxemon project", "(github.com/Tuxemon/Tuxemon)", ""]
for s in chosen:
    nm = out_mons[s]["name"]
    hit = next((b.strip() for b in blocks if b.startswith(f'* ["{nm}"]')), None)
    txt.append(plain(hit) if hit else f'"{nm}" from the Tuxemon project')
txt += ["", "FONT", "Press Start 2P by codeman38", "SIL Open Font License"]
open(f"{GAME}/data/credits.txt", "w", encoding="utf-8").write("\n".join(txt) + "\n")
