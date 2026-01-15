# Deficit-Based Healing Engine for Cleric

## Overview

A healing system that selects heals based on raw HP deficit (HP lost) rather than percentage. This solves the fundamental problem where percentage-based healing treats a tank at 70% (down 45k HP) the same as a caster at 70% (down 15k HP).

## Core Concept

Instead of asking "is this person below X%?", the system asks "how much HP has this person lost?" and picks a heal that matches the actual hole to fill.

**Benefits:**
- Prevents overhealing (wasting a 50k heal on 15k deficit)
- Prevents underhealing (using small heal on massive deficit)
- Naturally handles class differences without special configuration
- More mana efficient over time

## Architecture

### Component 1: Heal Tracker

Monitors all heals landing via events, recording spell name and actual heal amount.

**Data Tracked Per Spell:**
- Total heals landed (count)
- Running weighted average heal amount
- Recent trend (increasing/decreasing/stable)

**Weighted Average Formula:**
```
weight = 0.1 (configurable)
new_average = (old_average * (1 - weight)) + (new_heal * weight)
```

This approach:
- Naturally accounts for crit rate, focus effects, AAs
- Adapts as gear changes over time
- Resists skew from lucky crit streaks
- Stabilizes after ~20-30 heals per spell

### Component 2: Target Monitor

Watches two pools of heal targets:

**Priority Pool:**
- MT and MA roles auto-detected from raid window
- These are your assigned healing targets

**Group Pool:**
- Your group members
- Secondary responsibility

**Per Target Tracking:**
- Current HP
- Max HP
- HP deficit (max - current)
- Recent damage intake (rolling window)

### Component 3: Heal Selector

Picks appropriate spell based on context.

**Priority Order:**
1. Emergency (anyone <25% HP) → immediate fast heal
2. Group heal check (if efficient based on combined deficit)
3. Priority pool (MT/MA) by deficit
4. Group pool by deficit

**Selection Logic:**

For squishy targets (low max HP):
- Prefer fastest heal covering at least 70% of deficit
- Goal: stabilize quickly, return focus to tank

For tanks:
- Can use slower, bigger heals (they have HP buffer)
- Factor in mana efficiency

When multiple people hurt:
- Bias toward faster heals to spread attention
- Consider group heal efficiency

### Component 4: Group Heal Logic

Triggers based on raw HP deficit, not percentage.

**Conditions:**
- X+ people have deficit > Y HP (raw number)
- No one is in emergency state (<25%)
- Combined group deficit makes group heal efficient vs single target heals

**Efficiency Check:**
```
group_heal_value = expected heal amount × people hit
combined_deficit = sum of all group member deficits

Group heal is efficient when:
  - combined_deficit > group_heal_value
  - 3+ people would be healed
```

**Configuration:**
- Minimum deficit per person (raw HP)
- Minimum combined deficit
- Minimum target count

### Component 5: Proactive Heals (HoTs & Promised)

Used as gap fillers when situation is stable, not constant maintenance.

**Conditions for Proactive Healing:**
- No one below 25%
- No one in priority pool has deficit > 40% of max HP
- Not mid-cast on reactive heal

**HoT Logic:**

Apply HoT when:
- Target has a deficit AND
- Target has sustained damage (multiple hits in rolling window)
- HoT's healing value matches expected incoming damage

HoTs respond to damage patterns, not just "always keep HoT on MT."

**Promised Heals:**
- Best on tanks (likely to need it when it lands)
- Track pending Promised to avoid stacking
- Use during stable moments before anticipated damage

**Proactive Priority:**
1. HoT on target taking sustained damage
2. Promised on tank without one (if appropriate)
3. Spread HoTs to other priority targets if taking damage
4. Top off group with small deficits

## Performance Analytics

### Efficiency Metrics
- Overheal % per spell (heal landed vs deficit at cast time)
- Mana spent per effective HP healed
- Heal selection accuracy (right size for deficit?)

### Response Metrics
- Average time-to-heal by deficit severity
- Queue depth (how often multiple people waiting)
- Cast interruptions / target switches mid-cast

### Safety Metrics
- Critical events (drops below 25%, 15%, 10%)
- Deaths under your watch (with context)
- Near-misses (heals landing when target <20%)
- "Heal arrived too late" events

### Data Export
- All metrics logged with timestamps
- Session comparison (was today's config better?)
- Correlate deaths with specific situations
- Track trends as heal values update

## Configuration

### Thresholds
| Setting | Default | Description |
|---------|---------|-------------|
| Emergency HP % | 25% | Below this triggers immediate fast heal |
| Group heal min count | 3 | Minimum people hurt for group heal |
| Group heal min deficit | (tunable) | Raw HP deficit per person for group heal |
| Squishy max HP cutoff | (tunable) | Below this max HP = squishy class |

### Heal Selection
| Setting | Default | Description |
|---------|---------|-------------|
| Squishy coverage % | 70% | Minimum deficit coverage for fast heals |
| Overheal tolerance % | (tunable) | Acceptable overheal when picking heals |
| Cast time weight | (tunable) | Penalize slow heals when queue is deep |

### HoT Behavior
| Setting | Default | Description |
|---------|---------|-------------|
| Damage window (sec) | 5-10 | Rolling window for damage intake |
| Sustained damage threshold | (tunable) | Min DPS before HoT considered |

### Analytics
| Setting | Default | Description |
|---------|---------|-------------|
| Log verbosity | normal | minimal / normal / verbose |
| Session history | (tunable) | Sessions to retain for comparison |

### Spell Setup

Define which spells belong to each category:
- Fast single target (remedies)
- Medium single target (smaller interventions)
- Large single target (big interventions)
- Group heal
- HoT
- Promised

System learns heal values automatically; it just needs spell roles.

## User Interface

### Main Window Tabs

**Status Tab**
- Current heal targets with HP bars showing deficit
- Active HoTs/Promised with time remaining
- Mode indicator (normal / learning / emergency)
- Last action taken

**Heal Data Tab**
- Table of tracked spells:
  - Name, category, average value, sample count, trend
- Reset individual or all spell data

**Analytics Tab**
- Session stats (heals, efficiency, overheal %)
- Safety stats (criticals, deaths, near-misses)
- Response stats (reaction time, queue depth)
- Graphs if feasible

**Config Tab**
- All tunable settings
- Save/load configuration presets
- Toggle verbose logging

### Compact Mode
Collapsible minimal view:
- Assigned targets + HP bars
- Current state indicator

## Edge Cases

### Out of Mana
- Track mana, factor into decisions
- When low, prioritize efficient heals
- Emergency heals still fire regardless

### Target Dies Mid-Cast
- Detect death, abort if possible
- Immediately reassess priorities
- Log with context for analytics

### Multiple Emergencies
- Priority pool first (MT > group member)
- If tied, closest to death wins
- Log for config tuning

### Learning Mode (No Data)
- Default order: fast → medium → large
- Conservative heal value assumptions
- Never use large slow heals on squishies
- Flag "learning" in UI

### Tank Swap / Role Change
- Poll raid roles periodically
- Update priority pool on change
- Brief overlap where both get priority

### Stunned / Interrupted
- Detect failed casts, exclude from averages
- Reassess immediately on recovery

## Data Persistence

**Per-Character Config File:**
- Heal averages persist between sessions
- Analytics history for comparison
- Option to reset for fresh start

**Warmup Mode:**
- On first run or after reset
- Conservative fallback behavior
- Exits after X heals per spell

## Summary

| Component | Purpose |
|-----------|---------|
| Heal Tracker | Learn actual heal values via weighted average |
| Target Monitor | Track MT/MA + group, calculate deficits |
| Heal Selector | Pick heals by deficit, target type, situation |
| Group Heal Logic | Trigger on combined deficit, not percentage |
| Proactive System | HoTs/Promised as gap fillers based on damage patterns |
| Analytics | Track efficiency, response, safety for tuning |
| UI | Status, data, analytics, config with compact mode |

**Priority Order:** Emergency → Group heal → Priority pool → Group pool
