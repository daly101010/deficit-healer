# Deficit-Based Healer

A MacroQuest Lua healing script that selects heals based on **raw HP deficit** instead of percentage.

## The Problem

Traditional healing scripts heal at percentage thresholds (e.g., "heal when below 70%"). But 70% HP means very different things:
- Tank at 70% with 150k HP = **45k HP lost**
- Caster at 70% with 50k HP = **15k HP lost**

Percentage-based healing treats these identically when they're completely different situations.

## The Solution

This script asks "how much HP has this person lost?" and picks a heal that matches the actual deficit:
- Small deficit (10k) → fast, efficient small heal
- Medium deficit (40k) → bigger heal or HoT
- Large deficit (80k) → largest heal or emergency cooldowns

## Features

- **Self-learning heal values** - Tracks actual heal amounts with weighted averaging, auto-adapts to gear/AA changes
- **Situational heal selection** - Fast heals for squishies, efficient heals for tanks
- **Smart group heals** - Triggers on combined deficit, not percentage
- **Proactive healing** - HoTs based on damage patterns, not constant upkeep
- **Performance analytics** - Track efficiency, response times, critical events
- **Full ImGui UI** - Status, heal data, analytics, and config tabs

## Installation

1. Copy the `lua/deficithealer` folder to your MacroQuest `lua` directory
2. In-game: `/lua run deficithealer`

## Commands

- `/deficithealer` or `/dh` - Toggle script on/off
- `/dhui` - Toggle UI window

## Configuration

Configure spells and thresholds via the in-game UI Config tab.

## Documentation

- [Design Document](docs/plans/2026-01-14-deficit-based-healing-design.md) - Full system design
- [Implementation Plan](docs/plans/2026-01-14-deficit-healer-implementation.md) - Step-by-step build guide

## Status

**In Development** - Design complete, implementation planned.
