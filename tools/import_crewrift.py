"""Extract Crewrift's authored floor and markers with Blender --python."""

import json
import math
import shutil
import sys
from pathlib import Path

import bpy

ROOT = Path(__file__).resolve().parents[1]
ART = ROOT.parent / "polyworld_art" / "crewrift"
DATA = ROOT / "examples" / "crewrift" / "data"
STEP = 8
WIDTH = 1235
HEIGHT = 659


def pixel(point):
    """Convert Blender XY into the original ship's pixel coordinates."""
    return ((point[0] + 6.175) * 100, (3.295 - point[1]) * 100)


floor = bpy.data.objects["Plane002"]
floor.data.calc_loop_triangles()
vertices = [list(floor.matrix_world @ vertex.co)
            for vertex in floor.data.vertices]
triangles = [list(triangle.vertices)
             for triangle in floor.data.loop_triangles]
floor_name = floor.name
light_positions = [(obj.name, list(obj.matrix_world.translation))
                   for obj in sorted(bpy.data.objects, key=lambda obj: obj.name)
                   if obj.name.startswith("taskSeatLight")]
points = [pixel(point) for point in vertices]


def contains(x, y):
    """Test the union of the authored floor triangles."""
    for triangle in triangles:
        a, b, c = [points[index] for index in triangle]
        edges = [(b[0] - a[0]) * (y - a[1]) - (b[1] - a[1]) * (x - a[0]),
                 (c[0] - b[0]) * (y - b[1]) - (c[1] - b[1]) * (x - b[0]),
                 (a[0] - c[0]) * (y - c[1]) - (a[1] - c[1]) * (x - c[0])]
        if min(edges) >= -0.00001 or max(edges) <= 0.00001:
            return True
    return False


columns = math.ceil(WIDTH / STEP)
rows = math.ceil(HEIGHT / STEP)
tiles = [[contains(x * STEP + STEP / 2, y * STEP + STEP / 2)
          for x in range(columns)] for y in range(rows)]
sys.path.insert(0, str(ROOT / "tools"))
from audit_crewrift import audit, check_collisions, export_probes

check_collisions()
report = audit(tiles, ROOT.parent / "crewRift-map1-textured.glb",
               STEP, WIDTH, HEIGHT)
centers = [(x * STEP + STEP // 2, y * STEP + STEP // 2)
           for y in range(rows) for x in range(columns) if tiles[y][x]]
remaining = {(x, y) for y in range(rows) for x in range(columns)
             if tiles[y][x]}
queue = [remaining.pop()]
for x, y in queue:
    for neighbor in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]:
        if neighbor in remaining:
            remaining.remove(neighbor)
            queue.append(neighbor)
assert not remaining, "The floor must be one connected navigation component."


def nearest(x, y):
    """Snap an interaction marker onto a reachable tile center."""
    return min(centers, key=lambda p: (p[0] - x) ** 2 + (p[1] - y) ** 2)


metadata = json.loads((DATA / "croatoan.json").read_text())
original_tasks = metadata["tasks"]
tasks = []
markers = []
for name, position in light_positions:
    x, y = pixel(position)
    original = min(original_tasks, key=lambda task:
                   (task["x"] + task["w"] / 2 - x) ** 2 +
                   (task["y"] + task["h"] / 2 - y) ** 2)
    nx, ny = nearest(x, y)
    tasks.append(dict(original, resourceName=name,
                      x=nx - 7, y=ny - 7, w=14, h=14))
    markers.append({"name": name, "position": position,
                    "pixel": [nx, ny]})
assert len({(task["x"], task["y"]) for task in tasks}) == len(tasks), \
    "Task markers must occupy distinct tiles."
metadata["tasks"] = tasks
for vent in metadata["vents"]:
    x, y = nearest(vent["x"] + vent["w"] / 2,
                   vent["y"] + vent["h"] / 2)
    vent.update(x=x - vent["w"] // 2, y=y - vent["h"] // 2)
home = metadata["home"]
home["x"], home["y"] = nearest(home["x"], home["y"])
metadata["button"].update(x=home["x"] - 14, y=home["y"] - 17)
for room in metadata["rooms"]:
    local = [(x, y) for x, y in centers
             if room["x"] <= x < room["x"] + room["w"] and
             room["y"] <= y < room["y"] + room["h"]]
    assert local, "No floor inside room " + room["name"]
    room.update(x=min(x for x, y in local) - STEP // 2,
                y=min(y for x, y in local) - STEP // 2,
                w=max(x for x, y in local) - min(x for x, y in local) + STEP,
                h=max(y for x, y in local) - min(y for x, y in local) + STEP)
metadata.update(name="Crewrift map 1", path="map1")
ART.mkdir(parents=True, exist_ok=True)
links = [[0] * columns for _ in range(rows)]
for link in report['blockedLinks']:
    x, y = link['start']
    nx, ny = link['end']
    links[y][x] |= 1 if nx != x else 2
(DATA / "map1-links.txt").write_text("\n".join(
    "".join(str(value) for value in row) for row in links) + "\n")
(DATA / "map1-audit.json").write_text(json.dumps(report, indent=2) + "\n")
(ART / "navigation.json").write_text(json.dumps({
    "source": "crewRift-map1.blend", "object": floor_name,
    "vertices": vertices, "triangles": triangles, "tasks": markers,
    "modelScale": 12.5, "pixelsPerTile": STEP,
}, indent=2) + "\n")
(DATA / "map1.json").write_text(json.dumps(metadata, indent=2) + "\n")
(DATA / "map1-tiles.txt").write_text("\n".join(
    "".join("#" if tile else "." for tile in row) for row in tiles) + "\n")
shutil.copy2(ROOT.parent / "crewRift-map1-textured.glb",
             ART / "crewRift-map1-textured.glb")
print("CREWRIFT IMPORT", len(centers), "connected tiles,", len(tasks), "tasks")

for argument in sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []:
    if argument.startswith('--probes='):
        export_probes(report, ROOT / argument.split('=', 1)[1], STEP, WIDTH, HEIGHT)
