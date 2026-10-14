# Stations: coverage map

Agreed scope (2026-10-14): eight stations, not twelve. The line runs 23,000
studs; Ward Hill stays the ending. V2's catalogue was adapted to the existing
story rather than replacing it.

| # | Station | Distance | Story role | Landmark | Required work | Signature | Built | Tested |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Marrow Halt | 1,750 | First stop; the porter | water tower, station house | fuse, power, fuel | second dispatcher on the way | yes | full runs |
| 2 | Tolbridge Camp | 4,200 | The first real voice dilemma | loader, saw shed | interlocks (solo timer), loader, fuel | saw-shed mimic, the child | yes | full runs |
| 3 | Ninety-Three | 7,100 | The radio starts lying | signal tower, gantry | relay, read the frame, levers | the passenger (after) | yes | full runs |
| 4 | Hallow Bridge | 10,400 | The span; holding under pressure | the span, pump house | valve, prime the pumps (hold), lower the span | river mimic, ganger | yes | full runs |
| 5 | Calder Exchange | 13,500 | The Empty Exchange: left luggage, a branch not on the map | booking hall, left luggage, junction box | fuse, power the box, set the points; fuel | departures board, ticket stubs, branch diagram | new | played: all required objectives cleared |
| 6 | Blackglass | 16,400 | Reflections that are not exact | glass hall, halt office | light the halt, read the code in the glass, three levers | false voice: "leave the lights off" | new | played: all required objectives cleared |
| 7 | Station Zero | 19,300 | Not on any map; the crew's own reels | station office, archive, signal box | breaker, wake the board, hold the frame 90 s | reel in your own voice; "PLAY IT TO THEM" | new | played: all required objectives cleared |
| 8 | Ward Hill Relay | 22,200 | The truth and the ending | relay hall, mast | power the relay, the transmitter, hold the mast | the recording; the Dispatcher | yes (moved) | played to the ending at its new place |

New building kinds: `glass_hall` (mirrored dark glass), `luggage_heap`
(abandoned cases). New radio beats for stations 5 to 7.

## Part budget

Extending the line from 14,000 to 23,000 studs took a lane from 28,021 parts
to 47,708, nearly all of it forest. Forest density went from 3.5 to 2.1 per
10,000 square studs, and far trees lose small branches and brambles as they
already lost roots: a lane is now 32,526 parts (track 7,421, forest 20,627,
stations 4,415). The forest is visibly thinner; streaming means a client
only loads the part near it.

## Studio test tools

`StartAtStation` (server-set attribute on the crew leader) starts a run just
short of a station. Studio only.

## Not tested or open

* An uninterrupted run through all eight stations in one sitting (stations
  1 to 4 and 5 to 8 were played in separate runs).
* Optional objectives at the new stations (the harness skips optional ones).
* Night runs over the new segments, and the cut-off route with eight stations.
* Signal calls at the new stations: none authored yet (the twelve calls are
  at stations 1 to 4 and Ward Hill).
* Visual review of the three new stations from player height.
