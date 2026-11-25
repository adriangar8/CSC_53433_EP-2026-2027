# Kingdoms: design

**Status: draft, will change.**

A medieval evolution simulator. Two kingdoms (red and blue soldiers) are each other's predator and prey. Final project for "Creative and Generative Models in CG"; defense on Dec 16.

## World

- Two kingdoms on either side of a river carved by physical erosion. The river is impassable except at bridges.
- Castles (safe zones; dark green cover cells today) and gardens (food; light green) on each kingdom's own side.
- A dirt battlefield in between.

## Agents and evolution

- A soldier's genes are English sentences. An LLM (JEV) reads them and picks actions.
- Between generations an LLM mutator (gemma4:26b) rewrites the genes.

Current configuration:

- Species `red` and `blue`, each eating Grass and the other species; kill chance 0.5.
- Actions: hunt, eat, rest, mate, follow.
- 6 soldiers at start, floor 3, cap 15, maturity 150.
- Flat 48 m ground.

## Planned

- Scale to 192 m (like `Lab1_Full`).
- Sub-economies (peasants, animals).
- War and peace cycles.
- "A civilization that grew from the river".
- Our own architectural or mathematical patterns on buildings (procedural castles, fractal or spiral brushes).

## Open questions

- Sub-economy design.
- How wars start and stop.
- The defense format.
