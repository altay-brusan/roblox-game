# Ownership and publishing

Who gets paid, and what has to be true for that to be RIPjafar1.

---

## The single thing that matters

**Robux is paid to the owner of the experience the products belong to.**

Not to the account that wrote the code. Not to whoever is named in a config
file. Not to whoever the game is about. The experience owner, and nobody else.

This project contains the string `RIPGAMES` in several places and lists
`RIPjafar1` and `shayanbrusan1234` in `Admin.luau`. **None of that directs
payment.** Those are a studio name for display and two usernames for role
assignment. Ownership is decided entirely by which account or group you select
when you publish the place.

---

## The two ways to own it

### Publish under the RIPjafar1 account

Robux from Game Passes and Developer Products is credited to that account's
balance, subject to Roblox's platform cut and the usual payout rules.

Simplest option. Choose it if one person is running this.

**To do it:** in Studio, File, Publish to Roblox As, create a new experience,
and leave the creator as your own account.

### Publish to a Roblox group

Robux is credited to the group's funds. A group owner can then pay out to
members, either as a one-off payout or as a recurring percentage.

Choose this if more than one person is meant to share the income, or if the
RIPGAMES name is meant to be a real group other people can join.

**To do it:** create the group first at
<https://www.roblox.com/groups/create>, then in Studio's publish dialog select
the group as the creator.

Publishing to a group requires the publishing account to have the group's
**Create and edit experiences** permission. If RIPjafar1 owns the group, that
is automatic.

---

## Moving it later is possible but awkward

A published experience can be transferred from a user to a group they own, but
not between two users, and not from a group back to a user. Products
associated with the experience move with it.

Decide before you publish. It is a two-minute decision now and a real problem
later.

---

## What has to be true for RIPjafar1 to be paid

All of the following, not some of them:

1. The experience is published under the RIPjafar1 account, or under a group
   RIPjafar1 owns and takes payouts from.
2. The Game Passes and Developer Products are created **on that same
   experience**. A product created on a different experience will not work and
   pays a different owner.
3. The numeric IDs of those products are pasted into
   `src/shared/Config/Monetization.luau`, and the place has been rebuilt and
   republished with them.
4. The place is public, or at least accessible to the people expected to buy.

If any one of those is wrong, either nothing sells or somebody else is paid.

---

## Publishing checklist

Before you make it public:

- [ ] Decide account or group ownership. See above.
- [ ] Publish the place. File, Publish to Roblox As.
- [ ] Fill in the two administrator user IDs in `Admin.luau`. Until you do,
      nobody can administer the live game. See [ADMIN.md](ADMIN.md).
- [ ] Create the Game Passes and Developer Products and paste the IDs into
      `Monetization.luau`. See [MONETIZATION.md](MONETIZATION.md).
- [ ] Fill in at least the critical audio cues. See [AUDIO.md](AUDIO.md). The
      game is playable silent, but it is not frightening silent.
- [ ] Set the experience's maximum players to match
      `GameConfig.MaxServerPlayers`, which ships at 12.
- [ ] Under Game Settings, Security, enable **Enable Studio Access to API
      Services** only if you intend to test against live data from Studio. It
      is not needed for the live game.
- [ ] Set an age rating and fill in the experience description. This game has
      an original creature, no gore, and darkness; rate it honestly.
- [ ] Run through [TESTING.md](TESTING.md) on the published place with at least
      two players. Several systems, including crews, revives and the
      simultaneous objective, cannot be exercised alone.
- [ ] Read [STATUS.md](STATUS.md) so you know what has and has not been run.

---

## A note on claims

This project makes no prediction about how the game will perform. Whether a
Roblox experience finds an audience depends on discovery, timing, competition,
marketing and luck, none of which are properties of the code.

What the code can do is not get in the way: the free experience is complete,
the paid content is desirable rather than coercive, the data layer will not
lose progress, and the purchase handling will not lose a receipt. That is the
part that is under your control, and it is the part this project has tried to
get right.
