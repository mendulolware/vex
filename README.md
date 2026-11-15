# Vex

Linoria-based ragebot for Rivals (Luau, Byte executor).

- Silent aim: `Raycast`, `FindPartOnRay*`, `ScreenPointToRay`, `ViewportPointToRay`, `Mouse.Hit/Target`
- Auto fire, prediction, hit chance, team/wall checks
- Anti-aim: Spin, Jitter, Random, optional velocity desync
- Debug: Data2Code logger for `FireServer` args

## Run

```lua
loadstring(readfile("vex/Main.lua"))()
```

Menu key: RightShift. Untested in-game; use the remote logger to confirm which aim channel Rivals uses.
