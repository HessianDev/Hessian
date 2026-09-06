# Hessian: A Robot Simulator



**Hessian** is an open-source, low-poly 3D robotics simulator built in Godot 4.6. Construct custom robots using modular parts inspired by VEX V5 hardware—motors, pistons, axles, gears, and structural frames—program their behavior in an integrated visual block coding editor, and test your builds inside a real-time physics sandbox.

## Current Features

* **Modular Assembly:** Place and connect structural parts, axles, gears, pneumatic pistons, and motors.


* **Visual Block Editor:** Program autonomous logic and driver control schemes directly within the simulator.


* **Physics Sandbox:** Drive and operate your mechanisms live on a dynamic field environment.


* **Presets & Persistence:** Save/load custom robot builds or launch starter presets to jump right into testing.



## How to Use

You can download it from the releases section and run the .exe, or play the web version

* **Build:** Start a new robot assembly or load a saved design from the build workspace. Place structural pieces, add mechanisms, and wire up components.


* **Code:** Place a V5 Brain on your build, select it, and click **To Code Editor** to configure controller inputs and autonomous logic.


* **Test:** Click **Test Robot** to deploy your design onto the field and verify your code execution in real time.



## Known Issues

* Physics skipping can occasionally cause component clipping under heavy physics loads.


* Pneumatic pistons currently work best on simple mechanical systems (such as the `BasicRobot` preset).


* The robot simply does not exist when spawning for a test drive on web build (see **Technical Notes**)



## Planned Features

* **More parts** such as
  * Sensors that give imperfect data and refresh rates (Distance Sensor, Inertial Sensor)
  * Batteries and watts/ voltage for brain > motors (affecting temperature and efficiency)
  * Standard and Mecanum wheels with adjustable grip
  * More gears like worm gears, internal circle gears and rack gears
  * Chains & Links with plastic flaps
  * Pulleys & Rope
  * Air tanks with simulating air pressure and such for forces
  * Custom plexiglass plates and foam meshes

* Expanded visual programming blocks and python support.

* Debug system in testing robot scene (be able to hover over/ select parts and joints to see their stats)

* Structured game field challenges (possible VEX/RECF ones as well)



## Technical Notes

* **Godot 4.6 vs. 4.7+:** Hessian relies on specific joint features provided by the external Godot Jolt extension. Until the editor-embedded version of Jolt reaches full joint feature parity in newer engine builds, development will remain on Godot 4.6.


* **Physics Backend:** `Box3D-godot` was evaluated as a alternative engine backend, but adapting the custom robotics system presented significant integration hurdles. Development is locked to Jolt for stability, though community forks testing alternate physics engines are always welcome!

* **Web Build Errors:** Currently, you cannot load robots onto the field in the web version, this is because the Jolt plugin version currently doesn't support wasm32 builds, so it doesn't work for all browsers
