# RemoteCrab — Kickstarter Campaign Copy

> Status: draft for review. Not submitted.
> Updated: 2026-09-29
> Purpose: the complete copy for a Kickstarter campaign. Reusable for Indiegogo
> (drop the tier caps / swap the fulfilment language) and for the website's
> `/funding/` page.

---

## 0. Facts that constrain this document

- **The app is free today and the free tier never changes.** This campaign is
  not a pre-sale of software that already exists — it funds **Pro**, a new
  product layer that does not exist yet.
- **The free tier is a complete product, not a demo.** Camera, microphone,
  trackpad, keyboard, voice dictation, window mirroring, notification relay and
  context modes ship free, forever, to everyone including everyone reading this
  page right now.
- **macOS Continuity Camera already turns an iPhone into a wireless webcam, for
  free, built in.** We say this in the campaign. See §5 FAQ.
- **Extended Display runs on undocumented macOS classes.** It is a stretch
  goal, not a Pro promise. See §6.
- **"Mac" is Apple's trademark.** Fine on Kickstarter (nominative use), but the
  App Store submission must keep using "computer" (lesson 53). Two vocabularies,
  do not let them mix.
- Campaign page is **English**. The product is bilingual; the campaign is not
  negotiable on that.
- **Do not launch before iOS 1.0 is approved and live.** An empty App Store
  page reads as "is this project real?"

---

## 1. Project setup

| Field | Value | Why |
|---|---|---|
| Country | United States | The entity holding the funds |
| Currency | USD | |
| Category | Apps | Software, not hardware |
| Funding goal | **$25,000** | The minimum that ships Pro for macOS + iOS. See §1.1 |
| Duration | **30 days** | Kickstarter's stated sweet spot |
| Launch day | Tuesday or Wednesday, 9:00 am PT | Two consecutive KS campaigns in the sample set launched Tue/Wed |
| Team | Solo (no co-creator) | You are the developer, which satisfies KS's "must be run by the developers themselves" rule |
| Add-ons | Yes | Cheap add-ons lift average pledge without adding tiers |

### 1.1 The goal is a budget, not an ambition

Kickstarter's goal is a promise. Set it at the number below which Pro does not
ship, and defend it if a backer asks.

| Line | Amount |
|---|---|
| Pro for macOS + iOS: agent mode, multi-device, 4K, recording studio, team layer, Extended Display hardening | $15,000 |
| Contractor: Android capture client | $6,000 |
| Design + QA + a second pair of eyes on the Pro tier | $3,000 |
| Legal, accounting, tooling | $1,000 |
| **Total** | **$25,000** |

If the campaign raises less than $25,000, no one is charged, and the campaign
page says what the fallback is. (Write the fallback. A visible fallback is the
difference between "failed campaign" and "we tried".)

---

## 2. Title, tagline, short description

**Title** (60 chars):

```
RemoteCrab: Turn Your iPhone Into a Second Screen for Your Mac
```

**Tagline / one-liner** (used on the card, the video title card, the site):

```
The camera, microphone, trackpad, keyboard, second display and AI-agent
notifier for your Mac — from the phone already in your pocket.
```

**Short description** (180 chars, for the pre-launch page and the OG tags):

```
Your iPhone becomes a second screen, a camera, a mic, a trackpad and a
keyboard for your Mac. No cloud, no account, no subscription. Free tier
stays free forever. Fund the Pro layer.
```

---

## 3. The video — 60 seconds, three shots

The video is the single highest-leverage asset on the page. Three scenes, no
feature carousel. Reuse `scripts/marketing-video.sh` / HyperFrames.

| # | Seconds | Shot | The line |
|---|---|---|---|
| 1 | 0–15 | Mac mini with nothing plugged in. Zoom opens, the iPhone's camera is there. Switch to Final Cut, capture a window, drag the phone into a trackpad gesture. | "Mac mini users: the peripherals you need are already in your pocket. The first app to turn your iPhone into a camera, a microphone, a trackpad and a keyboard — and it's free." |
| 2 | 15–38 | A coding agent finishes a long run. The phone buzzes. A notification banner shows the app name. Tap it. The Mac wakes, that app comes forward, that window raises. | "Agents run for twenty minutes. Your attention shouldn't. The phone is the attention router: your Mac tells it what finished, and one tap drops you into the exact window that needs you." |
| 3 | 38–60 | Unplug the monitor. The phone is now a second display — drag a browser window onto it. Pinch, scroll, tap inside it. | "And when you want the phone to be a screen instead of a camera, it becomes one. A real second display for macOS. That's RemoteCrab Pro, and that's what your pledge funds." |
| — | 60 | Title card + "Free tier, forever free. Pro is what we're building." | |

**Rules:** real device, real macOS, real screen recording. No CGI. No stock
footage. No before/after with a fake UI. KS's rule on prototypes is explicit and
backers can tell.

---

## 4. The story page

Paste-ready. Section order matters — the first screen is all most people see.

---

### 4.1 Above the fold

> **Mac mini owners: the webcam, the microphone, the trackpad and the keyboard you are missing are already in your pocket.**
>
> RemoteCrab turns an iPhone or iPad into a full set of wireless peripherals for
> your Mac — camera, microphone, touchpad, keyboard, voice dictation, a mirrored
> app window, and now a real second display. No cloud. No account. No
> subscription. Ever.
>
> **The free tier stays free forever.** This campaign funds **Pro** — a new
> layer built on top of it, starting with the thing we think matters most: your
> phone as the attention router for your AI agents.

---

### 4.2 The problem

Three problems, three paragraphs. Do not list ten.

**The desk is missing pieces.** The Mac mini is a beautiful machine with no
camera, no microphone and no trackpad. The webcam market has settled on
"acceptable" — a $60 webcam is a compromise you accept, not one you want. The
camera in your phone is genuinely better than any of them. It just isn't
pointed at the right thing.

**Your attention is the bottleneck, not your hardware.** We now run coding
agents that work for twenty minutes. When one finishes, the notification lands
on a screen you are not looking at — and recovering context costs you minutes
every time. Not because the result is hard to find, but because finding it is
friction, and friction compounds across a whole day.

**A phone propped against a monitor is not a second screen.** Continuity Camera
already turns your iPhone into a wireless webcam. Apple is good at the easy
half of this. What it does not do is give you a display you can read and type
on, an input surface with real haptics, or a way to route an agent's output
back to the exact window that needs you.

---

### 4.3 What exists today, free, for everyone

Be concrete. Show the screenshots. This section is the credibility section.

- **Camera** — hardware H.264 encode, appears in every app on the system via a
  CMIO extension, including Zoom, FaceTime, OBS and Final Cut.
- **Microphone** — appears as a system input device. Verified end-to-end: it
  shows up in QuickTime, Zoom and Dictation.
- **Trackpad** — momentum scrolling, pinch, acceleration, haptic detents,
  multi-finger gestures, and a drag clutch that survives lifting your finger
  mid-selection.
- **Keyboard** — the system IME, so Chinese, dictation and emoji all work.
  Plus a shortcut bar and lockable modifiers.
- **Voice dictation** — hold to talk, on-device, types into the Mac.
- **App window mirroring** — see and control any app's window on the phone,
  with a modifier bar, double/triple click and pinch-zoom.
- **Notification relay** — Mac notification banners appear on the phone. Tap
  one and the Mac switches to that app *and raises that window*.
- **Context modes** — 18 control suites that reconfigure the shortcut bar based
  on which app is frontmost. Presenting in Keynote gets you presenter controls.
  Building in Xcode gets you build and test. Eighteen apps, forty-nine bundle
  IDs.

**None of this is going behind a paywall. None of it ever will.**

---

### 4.4 What your pledge funds: RemoteCrab Pro

This is the section that has to survive the most hostile reading. Every item
below is a commitment with a date.

**Tier 1 — ships on the campaign's delivery date:**

- **Agent mode.** Context chips for the agents you actually run. One tap from
  the phone: bring an app forward, raise a specific window, hand it input.
  The notification relay already does the last half; this is the other half.
- **Multi-device.** One phone to several Macs, and several phones to one Mac,
  with a switcher that shows what each one is doing.
- **4K and high bitrate capture.** Above the 1080p the free tier ships.
- **Recording studio.** Record the camera, the audio, or the mirrored window to
  disk with titles and a scrub bar.
- **Team layer.** Shared context-mode suites, a shared device roster, and
  priority support.

**Tier 2 — unlocked at $50,000:**

- **The Android capture client.** Your Pixel becomes the same camera, mic,
  trackpad and second screen. The protocol is already platform-agnostic; the
  client is the missing half.

**Tier 3 — unlocked at $100,000:**

- **A physical dock.** We design and build one: an aluminium stand for the
  phone with a built-in adjustable light, because "iPhone as webcam" is a
  hardware problem wearing a software costume — angle and lighting. Every
  backer at this level gets one, and it gets its own Kickstarter with the
  money already in it.

**Stretch goal we will not claim:** a documented, supported path to Extended
Display. It works today, but it runs on classes Apple has not documented, and we
will not sell you a promise that depends on Apple not changing. See §5.

---

### 4.5 Pro pricing, stated now so nobody has to guess

| | During the campaign | Afterwards |
|---|---|---|
| Personal, perpetual | **$39** (this campaign) | **$99** |
| 3 seats, perpetual | $149 | $249 |
| 10 seats, perpetual | $399 | $599 |
| 30 seats, perpetual | $999 | $1,499 |

**These licences are perpetual.** There is no subscription, no renewal, and no
recurring fee of any kind — the same promise the free tier makes.

**If you registered before this campaign launched, you get Pro free for twelve
months.** That promise is already live on the website and it will not change.

---

### 4.6 Risks

Write this section yourself, in the first person, and do not soften it. KS
backers read it and they respect it.

- **Apple ships this as a feature.** They partly already have. If a future macOS
  makes any part of this redundant, we will say so on this page and cut the
  affected tier.
- **Extended Display uses undocumented macOS classes.** It works on macOS 26. A
  future update could remove it. It is a stretch goal, not a Pro feature, and
  we will tell you the moment it breaks.
- **One person.** This is a solo project. It is also why the free tier is
  already as good as it is. If the campaign funds the plan above, it ships on
  the date above.
- **This is not a store.** You are helping to build a product that does not
  exist yet. Delivery dates on this page are estimates and we will post monthly
  updates either way.

---

## 5. FAQ

Answer the hostile ones first. Conceding something true builds more trust than
denying it.

**Apple's Continuity Camera already does the camera part. Why pay for this?**
It does. It is good, and it is free, and we say so on the top of this page. It
is also webcam-only: no trackpad, no keyboard, no voice, no mirrored window, no
second display, no agent routing, and no Windows. The free tier of RemoteCrab
covers everything Continuity Camera doesn't, at no cost.

**The app is free right now. Why would I pay for Pro?**
Because the free tier is a complete product and Pro is additive, not
restorative. You are funding things that do not exist yet — the Android client,
the agent mode, the team layer. You are not buying back something you already
had. If Pro doesn't ship on the date on this page, you are within your rights to
ask us for a refund and we will make it easy.

**Is this a pre-order of the existing app?**
No. Everything the free tier does is free, now and forever, and does not require
backing this campaign. This campaign funds a new product layer on top of it.

**Do I need a Mac?**
Yes for the receiver app. The capture app is iPhone or iPad. A Windows receiver
is in development and is on the roadmap; Mac and Windows are the same product
here, not a Mac-only product.

**How is this different from "just use a $60 webcam"?**
Different image sensor, different microphone array, different autofocus, and
you already own it. But that was never the interesting half of this product.

**Will the free tier disappear?**
No. There is a version of this business where we take the working parts away.
We are not running that version. The free tier is the reason anyone is reading
this page.

**What happens to my money?**
Kickstarter holds it and releases it to us only if we hit $25,000. If we miss,
you are never charged. If we hit and then can't deliver, that's between us and
you, and the answer is a refund — Kickstarter's rules say creators owe backers
a high standard of effort and honest communication, and we intend to be
accountable for that. We are a registered United States entity and the campaign
page shows it.

**Why are you selling an aluminium dock as a stretch goal instead of just making it?**
Because a dock is a manufacturing business and this is a software campaign. If
the third tier unlocks, the dock gets its own Kickstarter with this money already
in it, and you get a dock at cost.

**Do I need the phone plugged in?**
No. It's Wi-Fi, discovered over Bonjour, with a direct-IP fallback for
routers where multicast doesn't work — including some personal hotspots. There
is no cloud in the path.

---

## 6. Rewards

Five tiers. Kickstarter recommends no more than five for a first project.
Prices and caps are decided at launch; the caps are load-bearing — a capped
perpetual licence is both the protection and the urgency.

| Tier | Price | Cap | Contents |
|---|---|---|---|
| **Digital Supporter** | $1 | none | The newsletter, your name in the credits, every dev letter. No product. |
| **Founding Member** | $39 | 1,000 | **Perpetual Pro, personal** (a $99 licence at 39% off) + every stretch goal unlocked + a vote on the roadmap + beta channel. |
| **Founder's Edition** | $149 | 200 | Perpetual Pro × 3 seats + 3× roadmap vote weight + a Founder badge in the app + a **numbered CNC aluminium badge**, milled to order. |
| **Studio** | $399 | 50 | Perpetual Pro × 10 seats + a private channel + one roadmap call per quarter. |
| **Team** | $999 | 20 | Perpetual Pro × 30 seats + the team layer + your name in the app's credits. |

**Add-ons** (selectable on top of any tier):

| Add-on | Price | Notes |
|---|---|---|
| Extra perpetual Pro seat | $29 | |
| Extra aluminium badge | $35 | Only if the tier cap isn't reached — otherwise say so up front |
| Name in the credits, longer than most | $5 | Pure vanity, and it works |

**On the $1 tier.** It is not revenue. It is the seed the $39 tier is measured
against, and it is the cheapest possible way to get people onto the list. Cheat
Happens' $1 tip jar got 128 backers and 728 people bought the $299 lifetime
tier. Keep the low tier open; do not hide it.

**On the caps.** 1,000 / 200 / 50 / 20. These are not artificial scarcity
theatre. A perpetual licence is a person you support forever. Cap them, say the
caps out loud on the page, and put a countdown on the Founder's Edition.

---

## 7. Stretch goals

Public, automatic, in the order they unlock. On Indiegogo these are built in;
on Kickstarter they are a manual section you must remember to update.

| Unlocked at | Adds |
|---|---|
| $50,000 | The Android capture client |
| $75,000 | 4K screen mirroring (above the 1080p Pro ships) |
| $100,000 | The physical dock, for every backer at $999+ |
| $150,000 | Public roadmap voting, permanently — every backer keeps the vote |

---

## 8. Estimated delivery

Staggered, and generous. Underpromise, overdeliver.

| Tier | Estimated delivery |
|---|---|
| $1 Digital Supporter | Immediately after the campaign |
| $39 Founding Member | Within 2 weeks of the campaign ending |
| $149 Founder's Edition (with the milled badge) | 3 months |
| $399 Studio / $999 Team | 2 months |

The badge is the long pole because it is the only physical thing in the
campaign. Get the fabrication quote **before** the campaign goes live, not
after — that quote is a real cost in the budget in §1.1 and it is the reason the
$149 tier ships later than the $39 tier.

---

## 9. Pre-launch checklist

The campaign's success is decided here, not during the 30 days.

- [ ] **iOS 1.0 approved and live on the App Store.** Hard gate. Do not launch
      into an empty listing.
- [ ] **The website states the pricing table in §4.5 verbatim**, including the
      "registered before launch gets Pro free for twelve months" line. That
      promise must predate the campaign.
- [ ] **60-second video shot on a real device and a real Mac.** Not rendered.
- [ ] **KS pre-launch page live** with the "notify me" wall. Target 3,000
      followers before launch day; below 1,000 the campaign will not reach the
      goal.
- [ ] **Email list capture on the website**, sending to both the pre-launch page
      and Indiegogo.
- [ ] **Aluminium badge fabrication quote in hand**, and the badge design
      final enough to cut a die.
- [ ] **US entity documents ready**: W-9, articles, government ID, a bank
      account in the entity's exact name, and a credit card in the same name.
      Kickstarter will not open a project page without these.
- [ ] **A cross-border tax answer.** Money raised by a US entity is a US
      reporting event; the remittance to China is a separate domestic one. Get
      an accountant's answer before launch, not after the money lands.
- [ ] **One support channel ready.** Founder's Edition and above promise a
      private channel; it has to exist on day one.

---

## 10. Notes for the campaign owner

- **The word "Mac" is fine here.** The 5.2.5 rejection was App Store review's
  rule, not trademark law, and nominative use of a third-party product on a
  third-party platform is normal. The App Store copy must keep saying
  "computer" / "电脑". Do not let a copy-paste between the two leak.
- **The $99 anchor is the load-bearing number in §4.5.** It is what makes $39
  read as a discount instead of a price. If you change one number, change that
  one last and never let the post-campaign price drift down toward the campaign
  price.
- **Kickstarter locks the goal and the deadline at launch.** You can add tiers
  later; you cannot change or delete a tier that already has a backer.
- **The "dead zone" is real.** Kickstarter's own data shows a trough in the
  middle of every campaign. Plan the update schedule around it: front-load,
  prepare something real for day 14, and end with a live countdown.
- **Consider Indiegogo Express for a first run.** Backers pay at checkout,
  shipping details are collected immediately, and delivery can happen *during*
  the campaign. For a digital product with no manufacturing, that removes the
  all-or-nothing cliff entirely. Both platforms dropped flexible funding in
  2025, so Kickstarter's fixed goal is the only real difference left — and
  Express is a bigger one.
