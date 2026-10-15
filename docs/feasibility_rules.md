# Sanchari — the eight feasibility rules

The feasibility engine checks a trip stop by stop and day by day. Each rule below is a
precise test, written so it can be turned directly into SQL. The seed trips in
`db/data/trips.csv` are built against these definitions: ordinary trips pass all eight,
and one test trip per rule breaks exactly that rule (its `expect` column says which).

Times are compared as plain wall-clock times on the stop's own date.
"Monsoon" means a stop dated June to September.

| Rule | Name | A stop (or day, or trip) FAILS when… | Reads | Severity |
|---|---|---|---|---|
| **R01** | Closed that weekday | the place has no `opening_rule` row for the weekday of the stop's date | `opening_rule` via `f_place_open_on` | blocking |
| **R02** | Outside entry hours | arrival is before `opens_at`, or after the last entry time (`last_entry_at`, or `closes_at` when that is empty); or departure is after `closes_at` | `opening_rule` | blocking |
| **R03** | Inside a closure | the stop's date falls in a `closure_window` of the place (annual windows repeat every year) | `closure_window` via `f_place_open_on` | blocking |
| **R04** | Not enough travel time | previous stop's departure + travel minutes > this stop's arrival. Travel minutes come from `travel_leg` for the trip's primary mode (the monsoon figure in June-September, when there is one); if no leg exists, straight-line km × 1.3 ÷ the mode's `avg_speed_kmph` | `travel_leg`, `transport_mode` | blocking |
| **R05** | Too little time at a place | departure − arrival < the place's `typical_visit_minutes` | `place` | warning |
| **R06** | Daylight place after dark | the place `requires_daylight` and the stop runs outside 06:30–18:30 | `place` | blocking |
| **R07** | Too much travel in a day | total travel minutes between that day's stops > the owner's `max_travel_hours_per_day` × 60. Skipped when the owner has no profile or no limit | `traveller_profile`, `travel_leg` | warning |
| **R08** | Over budget | sum of all stops' `estimated_cost` + (each day's destination `base_cost_per_day` × `party_size`) > `budget_cap`. Skipped when `budget_cap` is empty | `itinerary_stop`, `destination`, `trip` | warning |

R01 and R03 come first for a stop: if a place is shut, R02 is not checked for it.

## How the engine reports a result

`CALL p_check_trip(trip_id)` (in `db/08a_feasibility_engine.sql`) writes one
`feasibility_run` row and one `violation` row per failure.

- **Where a violation points:** R01–R06 name the exact stop (trip, day, stop number).
  R07 belongs to a whole day and R08 to the whole trip, so their stop columns are empty
  and the message says which day.
- **Score:** 100 − 25 per blocking violation − 10 per warning, never below 0. It is
  copied to `trip.feasibility_score`.
- **Trip status:** a draft, validated or blocked trip becomes `blocked` if any blocking
  rule failed, otherwise `validated`. Locked and completed trips keep their status.
- **rules_evaluated:** 8, or less when R07 (owner has no travel limit) or R08 (trip has
  no budget) has nothing to compare against.
- **Refused:** a trip that does not exist or is cancelled raises an error and writes
  nothing.

## What `estimated_cost` holds

The cost of one stop for the whole party: entry fee (`fee_indian` × `party_size`) plus
the cost of getting there from the previous stop (road km × the mode's `cost_per_km`,
multiplied by `party_size` for bus and train, where each person buys a ticket).

## The test trips

| Trip | Breaks | How |
|---|---|---|
| T27 | R01 | Madikeri Museum on a Monday — it is closed on Mondays |
| T28 | R02 | arrives at the Kamalapur Archaeological Museum at 16:45 — last entry is 16:30 |
| T29 | R03 | Kote Betta in July — inside its annual monsoon closure |
| T30 | R04 | leaves Abbey Falls at 10:00 and "arrives" at Dubare at 10:10 — the drive takes far longer |
| T31 | R05 | 20 minutes at Mysore Palace — a visit takes 120 |
| T32 | R06 | on Hemakuta Hill until 19:00 — open, but a daylight-only place after 18:30 |
| T33 | R07 | a traveller who allows 3 hours of travel a day, on a day with over 3 hours of driving |
| T34 | R08 | a family of four on a ₹3,000 budget for a Mysuru day that costs far more |
