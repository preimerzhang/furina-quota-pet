import sys, runpy
from pathlib import Path
import bpy
root=Path(__file__).resolve().parent.parent
sys.argv=["build_card.py","--",str(root),"--skip-render"]
runpy.run_path(str(root/"scripts/build_card.py"),run_name="__main__")
scene=bpy.context.scene
scene.render.resolution_x=720
scene.render.resolution_y=1000
scene.cycles.samples=12
for frame,name in [(25,"hero"),(1,"tilt-left"),(49,"tilt-right")]:
 scene.frame_set(frame)
 scene.render.filepath=str(root/"renders"/(name+".png"))
 bpy.ops.render.render(write_still=True)
print("SCENE_AND_THREE_RENDERS_READY",flush=True)
