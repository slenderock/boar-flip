# Boar Flip

A World of Warcraft (Forever, Interface 16001) addon for making gold:

- **Bandages:** buy cloth on the auction house, craft First Aid bandages, sell them to a vendor.
- **Vendor deals:** scan the whole auction house for items a vendor pays at least 20c more for than they cost, and buy them one click at a time.

`/flip` opens it (it's off at every login); `/flip help` lists the commands.

## Install

Copy the `BoarFlip` folder into `World of Warcraft\_forever_\Interface\AddOns\`, then `/reload`.

## Tests

The game's script errors are off, so a broken addon just doesn't load. `tests/` catches that before it reaches the game. It needs [Node.js](https://nodejs.org):

```
cd tests
npm install
npm test
```

- **`check.js`:** checks syntax as Lua 5.1, flags unknown global names (usually a local used before it's declared), and checks Lua's limits of 200 locals and 60 upvalues per function. It also checks that every shared `ns.X` is set before it's used.
- **`run.js`:** runs the addon in `wowmock.lua`, a stand-in for the WoW API, under [fengari](https://fengari.io) (Lua in JavaScript). Then it plays each `scenario-*.lua`:
  - **deals:** a scan, then Buy next against the purchase answers seen in the game's log.
  - **bandages:** search, Buy, Open mail, Craft and Sell.
  - **smoke:** every event, button and slash command, checked for errors.

  `node run.js scenario-deals.lua` runs one scenario. `--toc other.toc` loads a different set of files.

fengari is Lua 5.3, not WoW's 5.1, which is why `check.js` checks the syntax separately.
