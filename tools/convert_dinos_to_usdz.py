"""
Converts Quaternius dino FBX files (one file per species, six embedded
animation actions: Idle/Walk/Run/Attack/Jump/Death) to USDZ for ModelIO
(FBX is unsupported by ModelIO on macOS 14+).

Unlike tools/convert_to_usdz.py (Mixamo layout: base mesh FBX + one FBX per
clip, "With Skin"/"Without Skin"), Quaternius ships all animation as actions
embedded in a single per-species FBX. This script also bakes each mesh's
flat multi-material shading (no UV maps on any of these assets) into a
per-vertex color attribute, since the runtime SkinnedVertex format doesn't
support multi-material rendering — see docs/PLAN-M3.md Decision 1.

Usage (from the MetalRex project root):
  /Applications/Blender.app/Contents/MacOS/Blender --background --python tools/convert_dinos_to_usdz.py
"""

import bpy, os, sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
SRC_DIR = os.path.join(PROJECT_DIR, "assets", "characters", "dinos")
OUT_ROOT = SRC_DIR

# (output directory name, source FBX basename)
SPECIES = [
    ("trex", "Trex"),
    ("velociraptor", "Velociraptor"),
    ("triceratops", "Triceratops"),
    ("stegosaurus", "Stegosaurus"),
    ("parasaurolophus", "Parasaurolophus"),
    ("apatosaurus", "Apatosaurus"),
]

# Canonical clip name -> suffix to match against action names, case-insensitive.
# Matches by suffix, not by full "<Species>_<Clip>" string, because at least
# one source file (Apatosaurus.fbx) has a misnamed action ("Stegosaurus_Death"
# instead of "Apatosaurus_Death") — a Quaternius authoring artifact. The
# action data itself is valid and correctly bound to that file's armature;
# only the string name is wrong. Matching by suffix fixes this at conversion
# time so the runtime loader never needs fuzzy string matching.
CLIP_SUFFIXES = {
    "idle": "_idle",
    "walk": "_walk",
    "run": "_run",
    "attack": "_attack",
    "jump": "_jump",
    "death": "_death",
}

FORCE = os.environ.get("REX_FORCE_CONVERT") == "1"


def clear_scene():
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)
    for action in list(bpy.data.actions):
        bpy.data.actions.remove(action)


def up_to_date(src, dst):
    if FORCE:
        return False
    return os.path.exists(dst) and os.path.getmtime(dst) >= os.path.getmtime(src)


def find_armature():
    for obj in bpy.context.scene.objects:
        if obj.type == 'ARMATURE':
            return obj
    return None


def find_mesh():
    for obj in bpy.context.scene.objects:
        if obj.type == 'MESH':
            return obj
    return None


def get_material_base_color(material):
    if material and material.node_tree:
        for node in material.node_tree.nodes:
            if node.type == 'BSDF_PRINCIPLED':
                return tuple(node.inputs['Base Color'].default_value[:])
    return (1.0, 1.0, 1.0, 1.0)


def bake_material_colors_to_vertex_color(mesh_obj):
    """Bakes each face's assigned material's base color into a per-corner
    color attribute, then strips the materials — the runtime renders these
    dinos via vertex color, not texture sampling (no UV maps exist on any
    of these meshes)."""
    mesh = mesh_obj.data
    mat_colors = [get_material_base_color(slot.material) for slot in mesh_obj.material_slots]
    if not mat_colors:
        mat_colors = [(1.0, 1.0, 1.0, 1.0)]

    # Named "displayColor" (not an arbitrary name) so it round-trips through
    # USD as the standard `primvars:displayColor` — ModelIO's USD reader maps
    # that specific, well-known primvar name to MDLVertexAttributeColor
    # ("color"). An arbitrarily-named color attribute (verified: "Color")
    # exports fine and is readable by other USD tools, but ModelIO's own
    # automatic MDL-semantic mapping doesn't recognize it, so CharacterLoader
    # silently treated every dino as textureless-and-colorless (default white)
    # despite the color data being genuinely present in the file.
    color_attr = mesh.color_attributes.new(name="displayColor", type='BYTE_COLOR', domain='CORNER')
    for poly in mesh.polygons:
        color = mat_colors[poly.material_index] if poly.material_index < len(mat_colors) else (1.0, 1.0, 1.0, 1.0)
        for loop_index in poly.loop_indices:
            color_attr.data[loop_index].color = color

    mesh_obj.data.materials.clear()


def match_clips(armature):
    """Matches each of the 6 canonical clip names to an action by suffix.
    Raises if any are missing — fail loud, not a silently incomplete clip
    table (matches the runtime load-time validation's own discipline)."""
    matched = {}
    for action in bpy.data.actions:
        name_lower = action.name.lower()
        for canonical, suffix in CLIP_SUFFIXES.items():
            if name_lower.endswith(suffix) and canonical not in matched:
                matched[canonical] = action

    missing = [c for c in CLIP_SUFFIXES if c not in matched]
    if missing:
        available = [a.name for a in bpy.data.actions]
        raise RuntimeError(
            f"Missing clips {missing} for armature '{armature.name}'. "
            f"Available actions: {available}"
        )
    return matched


def export_usdz(path, animated, with_colors):
    bpy.ops.wm.usd_export(
        filepath=path,
        export_animation=animated,
        export_uvmaps=False,
        export_normals=True,
        export_materials=False,
        export_mesh_colors=with_colors,
        export_shapekeys=False,
        export_armatures=True,
        use_instancing=False,
    )


def convert_species(out_name, fbx_basename):
    clear_scene()

    fbx_path = os.path.join(SRC_DIR, f"{fbx_basename}.fbx")
    if not os.path.exists(fbx_path):
        raise RuntimeError(f"{fbx_path} not found")

    bpy.ops.import_scene.fbx(filepath=fbx_path, ignore_leaf_bones=True, automatic_bone_orientation=True)

    armature = find_armature()
    mesh_obj = find_mesh()
    if not armature:
        raise RuntimeError(f"No armature found in {fbx_path}")
    if not mesh_obj:
        raise RuntimeError(f"No mesh found in {fbx_path}")

    print(f"Loaded {fbx_basename}: mesh='{mesh_obj.name}' "
          f"verts={len(mesh_obj.data.vertices)} bones={len(armature.data.bones)}")

    bake_material_colors_to_vertex_color(mesh_obj)
    clips = match_clips(armature)
    print(f"  matched clips: {[a.name for a in clips.values()]}")

    out_dir = os.path.join(OUT_ROOT, out_name)
    os.makedirs(out_dir, exist_ok=True)

    # Base mesh (rest pose, no action assigned) — vertex colors, no materials.
    if armature.animation_data:
        armature.animation_data.action = None
    base_out = os.path.join(out_dir, "base.usdz")
    if up_to_date(fbx_path, base_out):
        print(f"  base up to date: {base_out}")
    else:
        export_usdz(base_out, animated=False, with_colors=True)
        print(f"  exported base: {base_out} ({os.path.getsize(base_out)} bytes)")

    # Each canonical clip — same mesh+armature+colors, this action assigned,
    # frame range trimmed to the action's actual span. Matches the existing
    # CharacterLoader's expected clip-file shape (full scene per clip; the
    # loader bakes only the bone matrices out of it).
    for canonical_name, action in clips.items():
        clip_out = os.path.join(out_dir, f"{canonical_name}.usdz")
        if up_to_date(fbx_path, clip_out):
            print(f"  {canonical_name} up to date: {clip_out}")
            continue

        if not armature.animation_data:
            armature.animation_data_create()
        armature.animation_data.action = action
        fr = action.frame_range
        bpy.context.scene.frame_start = int(fr[0])
        bpy.context.scene.frame_end = int(fr[1])

        export_usdz(clip_out, animated=True, with_colors=True)
        print(f"  exported {canonical_name}: {clip_out} "
              f"({os.path.getsize(clip_out)} bytes, frames {int(fr[0])}-{int(fr[1])})")


for out_name, fbx_basename in SPECIES:
    print(f"\n=== {out_name} ===")
    convert_species(out_name, fbx_basename)

print("\nAll done.")
