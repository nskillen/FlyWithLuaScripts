# FlyWithLua Scripts

This repository contains the various scripts I have written to utilize FlyWithLua and X-Plane 11

Assuming that I have kept this readme up-to-date, the following scripts are available:

### Q4XP_Honeycomb_Helper

This script provides some useful interactions between the Honeycomb Bravo Throttle, and the FlyJSim Q4XP.

See commit note for further details, I don't feel like rewriting everything here right now.

It provides the following additional datarefs:

| Dataref                  | Type      | Description |
|--------------------------|-----------|-------------|
| `Q4XP_Helper/ap_lights`  | `int[7]`  | Can be used by Honeycomb Profile each int maps to a single autopilot mode light (0=HDG, 6=IAS) |
| `Q4XP_Helper/prop1_down` | `command` | Moves the condition lever for prop 1 from Feather to Fuel Cutoff |
| `Q4XP_Helper/prop1_up`   | `command` | Moves the condition lever for prop 1 from Fuel Cutoff to Feather |
| `Q4XP_Helper/prop2_down` | `command` | Moves the condition lever for prop 2 from Feather to Fuel Cutoff |
| `Q4XP_Helper/prop2_up`   | `command` | Moves the condition lever for prop 2 from Fuel Cutoff to Feather |
