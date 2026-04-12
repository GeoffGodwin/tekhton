# Design Document — Web Game

<!-- Generated from sections below -->

## Developer Philosophy & Constraints
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- What are your non-negotiable architectural rules for this game? Examples: -->
<!-- - Config-driven: all tunable values (speeds, costs, timers) live in config, never hardcoded -->
<!-- - Composition over inheritance: game objects built from composable behaviors, not deep class trees -->
<!-- - Interface-first: define system contracts before implementations -->
<!-- - Pure logic separation: game logic must be testable without a renderer -->
<!-- - Deterministic simulation: given the same inputs, game state must be identical -->
<!-- What patterns must every contributor follow from day one? What anti-patterns are banned? -->

## Project Overview
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- What is this game? What genre (roguelike, puzzle, platformer, RTS, idle, etc.)? -->
<!-- What is the core gameplay loop in one sentence? -->
<!-- What is the target audience (casual, hardcore, kids, etc.)? -->
<!-- What is the monetization model (free, premium, ads, in-app purchases, none)? -->
<!-- How does this game differentiate from similar games in the genre? -->

## Tech Stack
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- Rendering engine: Canvas 2D, WebGL, Three.js, Phaser, PixiJS, Babylon.js, or custom? -->
<!-- Language: TypeScript, JavaScript, or other? Why? -->
<!-- Bundler: Vite, Webpack, esbuild, Rollup? -->
<!-- State management: custom ECS, Redux, Zustand, or plain objects? -->
<!-- Physics engine (if any): Matter.js, Planck.js, custom, or none? -->
<!-- Audio library: Howler.js, Web Audio API directly, Tone.js? -->
<!-- Testing framework: Vitest, Jest, Playwright for E2E? -->

## Game Concept & Pillars
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- Describe the game in 2-3 paragraphs: setting, theme, and what makes it fun. -->
<!-- What is the "hook" — the thing that makes players want one more round? -->
<!-- List 3-5 design pillars (core values that guide every design decision). -->
<!-- Example pillars: "Easy to learn, hard to master", "Every run feels different", -->
<!-- "Decisions matter more than reflexes", "Visual clarity over visual complexity" -->
<!-- How do the pillars resolve design conflicts? (e.g., if accessibility conflicts with depth, which wins?) -->

## Player Resources & Economy
<!-- REQUIRED -->
<!-- PHASE:2 -->
<!-- What resources does the player earn, spend, and manage? -->
<!-- For each resource: name, how earned, how spent, upper/lower bounds, display format -->
<!-- Example: "Gold — earned from enemy drops (1-5 per kill), spent at shops, cap 9999, shown as integer" -->
<!-- What is the economic loop? (earn → spend → upgrade → earn faster) -->
<!-- Are there multiple currencies? How do they interact? -->
<!-- What are the inflation/deflation risks? How are they mitigated? -->
<!-- What values should be configurable vs hardcoded? Why? -->

## Core Mechanics
<!-- REQUIRED -->
<!-- PHASE:2 -->
<!-- List EACH gameplay mechanic as a ### sub-section. For each mechanic: -->
<!-- - Clear description of how it works from the player's perspective -->
<!-- - Inputs: what player action triggers this mechanic? -->
<!-- - Outputs: what changes in game state? -->
<!-- - Edge cases: what happens at boundaries? (empty inventory, max level, zero health) -->
<!-- - Interaction rules: how does this mechanic interact with other mechanics? -->
<!-- - Configurable values: what numbers should be tunable? (speeds, costs, durations) -->
<!-- - Balance notes: what could break if values are wrong? -->
<!-- Example sub-sections: ### Movement, ### Combat, ### Crafting, ### Inventory -->

## Game State Architecture
<!-- REQUIRED -->
<!-- PHASE:2 -->
<!-- What data defines the complete state of the game at any moment? -->
<!-- Organize into categories: player state, world state, UI state, session state -->
<!-- For each state object: key fields, types, default values, serialization notes -->
<!-- What is the state update model? (tick-based, event-driven, hybrid) -->
<!-- What is the tick rate / update frequency? Is it fixed or variable? -->
<!-- How is state isolated from rendering? Can you snapshot/restore state? -->
<!-- What state needs to survive a page refresh? What is ephemeral? -->

## Player Input & Controls
<!-- REQUIRED -->
<!-- PHASE:2 -->
<!-- How does the player interact? Keyboard, mouse, touch, gamepad? All of the above? -->
<!-- Map SPECIFIC inputs to SPECIFIC actions: -->
<!-- Example: "WASD/Arrow keys → move character, Space → jump, Left click → attack" -->
<!-- How are conflicting inputs resolved? (e.g., pressing left and right simultaneously) -->
<!-- Is input buffering used? What is the buffer window? -->
<!-- How does the control scheme adapt for mobile/touch? -->
<!-- Are controls rebindable? If so, how is the mapping stored? -->
<!-- What accessibility options exist? (one-handed mode, hold-vs-toggle, input sensitivity) -->

## Entity & Object System
<!-- PHASE:2 -->
<!-- How are game entities structured? (ECS, OOP hierarchy, data-oriented, hybrid) -->
<!-- What are the base entity types? (player, enemy, projectile, pickup, tile, UI element) -->
<!-- For each entity type: components/properties, creation rules, lifecycle (spawn → active → destroy) -->
<!-- How are entities identified? (numeric ID, UUID, index in array) -->
<!-- How are entity interactions resolved? (collision callbacks, event bus, direct method calls) -->
<!-- What is the entity pooling/recycling strategy for performance? -->

## Levels, Worlds & Progression
<!-- PHASE:2 -->
<!-- How does difficulty increase? Discrete levels, continuous scaling, procedural generation? -->
<!-- What defines a "level"? (tile map, wave list, parameter set, seed) -->
<!-- How is level data stored? (JSON files, procedural algorithm, editor-generated) -->
<!-- What is the progression structure? (linear, branching, open world, roguelike runs) -->
<!-- What unlocks between sessions? (permanent upgrades, new characters, new modes) -->
<!-- How is pacing managed? (difficulty curves, rest areas, boss encounters) -->
<!-- What configurable values control difficulty? (enemy count, spawn rate, damage multipliers) -->

## AI & Enemy Behavior
<!-- PHASE:2 -->
<!-- What types of AI-controlled entities exist? -->
<!-- For each enemy/NPC type: behavior pattern, detection range, attack pattern, weaknesses -->
<!-- What AI model is used? (finite state machine, behavior tree, utility AI, scripted) -->
<!-- How do enemies interact with the environment? (pathfinding, obstacle avoidance) -->
<!-- What difficulty-scaling behaviors change with level/wave? -->
<!-- Are AI parameters configurable? What are the tuning knobs? -->

## Collision & Physics
<!-- PHASE:2 -->
<!-- What collision detection method? (AABB, circle, pixel-perfect, tilemap-based) -->
<!-- What physics model? (arcade, realistic, none — pure logic) -->
<!-- Collision layers/groups: what collides with what? -->
<!-- Example: "Player ↔ Enemy = damage, Player ↔ Pickup = collect, Enemy ↔ Wall = block" -->
<!-- How are collision edge cases handled? (tunneling, corner cases, simultaneous hits) -->
<!-- What physics values are configurable? (gravity, friction, restitution) -->

## Scoring, Win/Loss & Achievements
<!-- PHASE:2 -->
<!-- How does the player score points? What actions award points? -->
<!-- Score multipliers, combos, or bonus conditions? -->
<!-- What ends a game session? (death, timer, objective completion) -->
<!-- What are the win conditions? Are there multiple endings/outcomes? -->
<!-- What is the defeat/game-over flow? (retry, back to menu, continue with penalty) -->
<!-- Leaderboard system? (local only, server-backed, friend-based) -->
<!-- Achievement/unlock system? List categories and examples. -->

## UI Layout & HUD
<!-- PHASE:2 -->
<!-- What does the player see on screen during gameplay? -->
<!-- HUD elements: health bar, score, timer, minimap, inventory, etc. -->
<!-- Menu structure: main menu → options → play → pause → game over -->
<!-- For each screen: layout description, interactive elements, transitions -->
<!-- How does the UI respond to different screen sizes? (responsive, fixed, letterbox) -->
<!-- What UI framework or approach? (DOM overlay, canvas-rendered, hybrid) -->
<!-- Accessibility: font sizes, color-blind modes, screen reader support? -->

## Art & Visual Direction
<!-- PHASE:2 -->
<!-- Visual style: pixel art, flat/vector, hand-drawn, 3D, realistic? -->
<!-- Art pipeline: who creates assets? What format? What tools? -->
<!-- Sprite/asset organization: naming conventions, directory structure, atlas strategy -->
<!-- Animation approach: spritesheet, skeletal, tweened, procedural? -->
<!-- Particle effects: what systems use particles? What parameters are configurable? -->
<!-- Camera behavior: fixed, following, zooming, shaking? -->
<!-- Color palette: defined palette or freeform? Color-blind considerations? -->

## Audio Design
<!-- PHASE:2 -->
<!-- Sound effects: what actions have sounds? (jump, hit, pickup, UI click, ambient) -->
<!-- Music: adaptive/interactive or static tracks? How many tracks? -->
<!-- Audio library choice and initialization pattern -->
<!-- Volume controls: master, SFX, music — stored where? -->
<!-- Audio asset format: MP3, OGG, WAV? Fallback strategy? -->
<!-- Mute behavior: what happens when tab is not focused? -->
<!-- Audio is often the most neglected system — what is the minimum viable audio plan? -->

## Save System & Persistence
<!-- PHASE:2 -->
<!-- Does progress save? What exactly is saved? (high scores, unlocks, mid-run state) -->
<!-- Storage: localStorage, IndexedDB, server-side, or cloud save? -->
<!-- Save format: JSON structure with version number? -->
<!-- Migration strategy: how do save files upgrade between game versions? -->
<!-- Save corruption handling: what happens if the save file is invalid? -->
<!-- Auto-save frequency and triggers (on level complete, on pause, on exit) -->

## Networking & Multiplayer
<!-- PHASE:2 -->
<!-- Is this single-player only, or is multiplayer planned? -->
<!-- If multiplayer: client-server, peer-to-peer, or relay? -->
<!-- Network protocol: WebSocket, WebRTC, HTTP polling? -->
<!-- Latency compensation: client prediction, rollback, lockstep? -->
<!-- If single-player: any online features? (leaderboards, daily challenges, analytics) -->

## Performance & Optimization
<!-- PHASE:2 -->
<!-- Target frame rate: 30fps, 60fps, or unlocked? -->
<!-- Supported browsers: Chrome, Firefox, Safari, Edge? Minimum versions? -->
<!-- Mobile support: yes/no? Touch controls? Responsive canvas? -->
<!-- Performance budgets: max draw calls, max entities, max particle count -->
<!-- Object pooling strategy: what entities are pooled? -->
<!-- Asset loading: preload everything, lazy load, or streaming? -->
<!-- Memory management: how are disposed assets cleaned up? -->

## Config Architecture
<!-- REQUIRED -->
<!-- PHASE:3 -->
<!-- What values MUST live in config files rather than hardcoded? -->
<!-- Config format: JSON, YAML, TypeScript const, .env? -->
<!-- Config loading: when and how is config loaded? Hot-reload in dev? -->
<!-- Show example config structures with actual keys and default values. Example: -->
<!-- ```json -->
<!-- { -->
<!--   "player": { "speed": 200, "maxHealth": 100, "invincibilityFrames": 60 }, -->
<!--   "enemies": { "spawnRate": 2.0, "baseSpeed": 100, "damageMultiplier": 1.0 }, -->
<!--   "economy": { "startingGold": 0, "goldCap": 9999, "shopPriceMultiplier": 1.0 } -->
<!-- } -->
<!-- ``` -->
<!-- What is the config override hierarchy? (defaults → file → env → runtime) -->
<!-- How do designers change values without touching code? -->

## Documentation Strategy
<!-- REQUIRED -->
<!-- PHASE:2 -->
<!-- What documentation does this project ship? (README only, README + docs/ site, wiki) -->
<!-- Where is documentation hosted? (GitHub, GitHub Pages, itch.io page) -->
<!-- What surfaces must be documented? (controls, game mechanics, config keys, modding API) -->
<!-- On every feature change, which docs must be updated in the same commit? -->
<!-- Is doc freshness strict (block the merge) or warn-only? -->
<!-- Any auto-generation tooling? (typedoc, JSDoc) -->

## Developer & Debug Tools
<!-- PHASE:3 -->
<!-- What debug/dev tools are built into the game? -->
<!-- Examples: FPS counter, hitbox visualizer, state inspector, level skip, god mode -->
<!-- How are debug tools enabled/disabled? (URL param, key combo, build flag) -->
<!-- Is there a debug console or command system? -->
<!-- What telemetry or analytics are collected during development? -->
<!-- How do you reproduce a bug? (state snapshots, replay system, seed logging) -->

## Naming Conventions
<!-- PHASE:3 -->
<!-- What code names map to what domain/lore concepts? -->
<!-- This is critical when lore/branding names are not finalized. -->
<!-- Example: "Orb" in lore = "currency_primary" in code, "The Void" in lore = "endless_mode" in code -->
<!-- Entity naming pattern: PascalCase classes, camelCase instances, UPPER_SNAKE config keys? -->
<!-- File naming: kebab-case, camelCase, or PascalCase? -->
<!-- Asset naming: how are sprites, sounds, and config files named? -->

## Open Design Questions
<!-- REQUIRED -->
<!-- PHASE:3 -->
<!-- What decisions are you deliberately deferring? Why? -->
<!-- What needs playtesting before you can decide? -->
<!-- What trade-offs have you identified but not resolved? -->
<!-- Example: "Unsure if crafting adds depth or just friction — need prototype" -->
<!-- Example: "Multiplayer scope TBD — build single-player first, then evaluate" -->
<!-- List each open question with the information needed to resolve it. -->

## What Not to Build Yet
<!-- PHASE:3 -->
<!-- What features are explicitly deferred to avoid scope creep? -->
<!-- For each deferred feature: what it is, why it's deferred, what milestone might add it -->
<!-- Example: "Level editor — deferred until core loop is proven fun (Milestone 8+)" -->
<!-- Example: "Achievements — nice-to-have, not blocking any other system" -->
