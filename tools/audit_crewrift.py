"""Audit Crewrift navigation with inset standing boxes against its GLB mesh.

Run through import_crewrift.py in Blender. Coordinates here use Blender XY
for the floor and Z for height, matching Blender's actual glTF import.
"""

import hashlib
import math
from collections import Counter, defaultdict

import bpy
import numpy as np
from mathutils import Vector
from mathutils.bvhtree import BVHTree

MODEL_SCALE = 12.5
INSET = 0.15
CREW_HEIGHT = 1.8
FLOOR_CLEARANCE = 0.08
EPSILON = 1e-7


def triangle_boxes(triangles, center, half):
    """Return exact triangle/box overlaps using all 13 separating axes."""
    vertices = triangles - center
    active = np.all(vertices.min(axis=1) <= half + EPSILON, axis=1)
    active &= np.all(vertices.max(axis=1) >= -half - EPSILON, axis=1)
    vertices = vertices[active]
    if not len(vertices):
        return False
    edges = np.roll(vertices, -1, axis=1) - vertices
    axes = [np.cross(edges[:, 0], edges[:, 1])]
    for edge in range(3):
        for axis in np.eye(3):
            axes.append(np.cross(edges[:, edge], axis))
    overlap = np.ones(len(vertices), dtype=bool)
    for axis in axes:
        projection = np.einsum('tvc,tc->tv', vertices, axis)
        radius = np.abs(axis) @ half
        overlap &= projection.min(axis=1) <= radius + EPSILON
        overlap &= projection.max(axis=1) >= -radius - EPSILON
    return bool(overlap.any())


def inside_mesh(mesh, point):
    """Detect boxes wholly inside solids with three independent parity rays."""
    if np.any(point <= mesh['low']) or np.any(point >= mesh['high']):
        return False
    if mesh['tree'] is None:
        mesh['tree'] = BVHTree.FromPolygons(
            mesh['vertices'].tolist(), mesh['indices'].tolist(),
            all_triangles=True)
    for direction in [(1, .317, .193), (.271, 1, .413), (.373, .239, 1)]:
        ray = Vector(direction).normalized()
        origin = Vector(point)
        crossings = 0
        for _ in range(256):
            hit, normal, index, distance = mesh['tree'].ray_cast(origin, ray)
            if hit is None:
                break
            crossings += 1
            origin = hit + ray * 0.000001
        else:
            raise RuntimeError('Too many mesh crossings: ' + mesh['name'])
        if crossings % 2 == 0:
            return False
    return True


def model_meshes(path):
    """Load precisely the visible mesh placements used by the ship skin."""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(path))
    meshes = []
    for obj in bpy.data.objects:
        if obj.type != 'MESH' or obj.hide_render:
            continue
        data = obj.data
        data.calc_loop_triangles()
        coords = np.empty(len(data.vertices) * 3, dtype=np.float32)
        indices = np.empty(len(data.loop_triangles) * 3, dtype=np.int32)
        data.vertices.foreach_get('co', coords)
        data.loop_triangles.foreach_get('vertices', indices)
        matrix = np.array(obj.matrix_world, dtype=np.float64)
        vertices = coords.reshape(-1, 3) @ matrix[:3, :3].T + matrix[:3, 3]
        indices = indices.reshape(-1, 3)
        meshes.append(dict(name=obj.name, vertices=vertices, indices=indices,
                           triangles=vertices[indices], low=vertices.min(axis=0),
                           high=vertices.max(axis=0), tree=None))
    return meshes


def probe_bounds(x, y, step, width, height):
    """Place a 15%-inset box from floor clearance up to standing crew height."""
    side = step / 100
    low = np.array([x * side - width / 200 + side * INSET,
                    height / 200 - (y + 1) * side + side * INSET,
                    FLOOR_CLEARANCE / MODEL_SCALE])
    high = low + [side * (1 - 2 * INSET), side * (1 - 2 * INSET),
                  (CREW_HEIGHT - FLOOR_CLEARANCE) / MODEL_SCALE]
    return (low + high) / 2, (high - low) / 2


def audit(tiles, model, step, width, height):
    """Check every candidate tile, keep the largest connected clear component."""
    rows, columns = len(tiles), len(tiles[0])
    candidates = {(x, y) for y in range(rows) for x in range(columns)
                  if tiles[y][x]}
    meshes = model_meshes(model)
    cells = defaultdict(list)
    for index, mesh in enumerate(meshes):
        if mesh['high'][2] < FLOOR_CLEARANCE / MODEL_SCALE or \
                mesh['low'][2] > CREW_HEIGHT / MODEL_SCALE:
            continue
        x0 = max(0, math.floor((mesh['low'][0] + width / 200) * 100 / step))
        x1 = min(columns - 1,
                 math.floor((mesh['high'][0] + width / 200) * 100 / step))
        y0 = max(0, math.floor((height / 200 - mesh['high'][1]) * 100 / step))
        y1 = min(rows - 1,
                 math.floor((height / 200 - mesh['low'][1]) * 100 / step))
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                if (x, y) in candidates:
                    cells[x, y].append(index)
    records = []
    clear = set()
    for x, y in sorted(candidates, key=lambda p: (p[1], p[0])):
        center, half = probe_bounds(x, y, step, width, height)
        blockers = []
        for index in cells[x, y]:
            mesh = meshes[index]
            if np.any(center + half < mesh['low']) or \
                    np.any(center - half > mesh['high']):
                continue
            if triangle_boxes(mesh['triangles'], center, half) or \
                    inside_mesh(mesh, center):
                blockers.append(mesh['name'])
        if not blockers:
            clear.add((x, y))
        records.append(dict(x=x, y=y, status='collision' if blockers else 'clear',
                            blockers=blockers))
    links = []
    for x, y in sorted(clear):
        center, half = probe_bounds(x, y, step, width, height)
        for nx, ny in [(x + 1, y), (x, y + 1)]:
            if (nx, ny) not in clear:
                continue
            other, _ = probe_bounds(nx, ny, step, width, height)
            midpoint = (center + other) / 2
            extent = half + np.abs(other - center) / 2
            blockers = []
            for index in sorted(set(cells[x, y] + cells[nx, ny])):
                mesh = meshes[index]
                if np.any(midpoint + extent < mesh['low']) or \
                        np.any(midpoint - extent > mesh['high']):
                    continue
                if triangle_boxes(mesh['triangles'], midpoint, extent) or \
                        inside_mesh(mesh, midpoint):
                    blockers.append(mesh['name'])
            if blockers:
                links.append(dict(start=[x, y], end=[nx, ny], blockers=blockers))
    blocked = {tuple(sorted((tuple(link['start']), tuple(link['end']))))
               for link in links}
    remaining = set(clear)
    components = []
    while remaining:
        queue = [min(remaining)]
        remaining.remove(queue[0])
        for x, y in queue:
            for point in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]:
                if point in remaining and tuple(sorted(((x, y), point))) not in blocked:
                    remaining.remove(point)
                    queue.append(point)
        components.append(set(queue))
    if not components:
        raise RuntimeError('The ship mesh has no clear navigation tiles.')
    kept = max(components, key=len)
    for record in records:
        point = record['x'], record['y']
        if record['status'] == 'clear':
            record['status'] = 'kept' if point in kept else 'disconnected'
        tiles[point[1]][point[0]] = point in kept
    links = [link for link in links if tuple(link['start']) in kept
             and tuple(link['end']) in kept]
    counts = Counter(record['status'] for record in records)
    report = dict(model=model.name, sha256=hashlib.sha256(model.read_bytes()).hexdigest(),
                  modelScale=MODEL_SCALE, insetPerEdge=INSET,
                  probeWidthTiles=1 - 2 * INSET, crewHeight=CREW_HEIGHT,
                  floorClearance=FLOOR_CLEARANCE, meshPlacements=len(meshes),
                  candidateTiles=len(candidates), counts=dict(counts),
                  clearComponentSizes=sorted([len(c) for c in components], reverse=True),
                  blockedLinks=links, tiles=records)
    print('CREWRIFT AUDIT', report['counts'], 'components', report['clearComponentSizes'], 'blocked links', len(links))
    return report


def check_collisions():
    """Check crossing faces, separated faces, touching faces, and solid interiors."""
    center, half = np.zeros(3), np.ones(3)
    assert triangle_boxes(np.array([[[-3, 0, 0], [3, -3, 0], [3, 3, 0]]]), center, half)
    assert not triangle_boxes(np.array([[[2, 0, 0], [3, -3, 0], [3, 3, 0]]]), center, half)
    assert triangle_boxes(np.array([[[1, 0, 0], [1, 3, 0], [1, 0, 3]]]), center, half)
    vertices = np.array([(x, y, z) for x in [-2, 2] for y in [-2, 2] for z in [-2, 2]])
    indices = np.array([(0, 1, 3), (0, 3, 2), (4, 6, 7), (4, 7, 5),
                        (0, 4, 5), (0, 5, 1), (2, 3, 7), (2, 7, 6),
                        (0, 2, 6), (0, 6, 4), (1, 5, 7), (1, 7, 3)])
    mesh = dict(name='Test cube', vertices=vertices, indices=indices,
                low=vertices.min(axis=0), high=vertices.max(axis=0), tree=None)
    assert not triangle_boxes(vertices[indices], center, half)
    assert inside_mesh(mesh, center)
    assert not inside_mesh(mesh, np.array([3, 0, 0]))
    print('CREWRIFT collision checks passed')


def export_probes(report, path, step, width, height):
    """Save an inspectable ship scene with one colored wire box per tested tile."""
    collection = bpy.data.collections.new('Navigation box probes')
    bpy.context.scene.collection.children.link(collection)
    mesh = bpy.data.meshes.new('Inset standing box')
    mesh.from_pydata([(x, y, z) for x in [-1, 1] for y in [-1, 1] for z in [-1, 1]],
                     [], [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1),
                          (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)])
    colors = dict(kept=(.1, .8, .2, 1), collision=(1, .1, .1, 1),
                  disconnected=(1, .6, .1, 1))
    for tile in report['tiles']:
        center, half = probe_bounds(tile['x'], tile['y'], step, width, height)
        obj = bpy.data.objects.new(f"Probe_{tile['x']}_{tile['y']}_{tile['status']}", mesh)
        collection.objects.link(obj)
        obj.location = center
        obj.scale = half
        obj.display_type = 'WIRE'
        obj.color = colors[tile['status']]
        obj.show_in_front = True
        obj.hide_render = True
        obj['blockers'] = ', '.join(tile['blockers'])
    for screen in bpy.data.screens:
        for area in screen.areas:
            if area.type == 'VIEW_3D':
                area.spaces.active.shading.color_type = 'OBJECT'
    path.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(path))
