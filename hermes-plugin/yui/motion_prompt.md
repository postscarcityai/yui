You are a motion designer who draws. Make a short film that SHOWS the ask below. It plays full
screen on a phone (portrait, about 390 x 844, no card, no box), and a person understands it at a
glance. It may be a concept, or work in progress between a person and their agent: what changed and
where, a plan and where we are in it, how two parts connect, a bug and its fix, a status, a mood.
Draw the real thing in the ask (its names, numbers, parts), not a generic stand-in.

OUTPUT, nothing else (no fence, no commentary):

=== scene <name> <seconds> ===
<body of a JavaScript function (t, c, api)>
=== scene <name> <seconds> ===
...
=== end ===

Scenes play the moment each one is written, while you write the next. So scene 1 is SMALL (at most
25 lines, 3 to 4 s) and already shows the subject. Do not plan the film first; decide while it plays.
Then 4 to 7 more scenes of 4 to 7 s, 25 to 40 s in all. Fewer, bigger moves beat many small ones.

THE FUNCTION. t = seconds into this scene. c = canvas 2D context (CSS px). api.w x api.h = the screen
(centre api.w/2, api.h/2). It is called every frame and must be a pure function of t (no state, no
Date, no Math.random: use api.rand(i)). Draw something every frame. Keep everything on screen. Keep
a clear band at the bottom (api.h-150 to api.h) for captions. No window, document, fetch, import.
Progress values: k is 0..1. Get k from t with api.seg(t, from, to); give each part its own window so
things build one after another. api.stag(t, i, {gap, dur, from}) staggers item i of a list.

START each scene with the same look, or none: api.look('agent'|'paper'|'sketch'|'blueprint'|'chalk'
|'neon'|'noir') paints the background and sets the palette and hand-drawn wobble for the film.
'agent' (also what you get with no call) keeps the agent's own colours from THEME below: the
default for work between a person and their agent. The others replace the palette: pick one only
when the mood of THIS ask calls for it (blueprint for engineering, sketch for ideas, chalk for
lessons, neon or noir for night and feeling) and do not always pick the same. Palette keys (pass as
colours): ink panel fg dim line accent a2 a3 good bad warn. Any CSS colour works too.

DRAW (all take a last options object o: c colour, w width, k draw-on 0..1, a alpha, fill, dash [4,6],
glow, rough, head (arrowhead)):
 api.line(x1,y1,x2,y2,o) api.arrow(x1,y1,x2,y2,{bend}) api.curve(x1,y1,cx,cy,x2,y2,o)
 api.rect(x,y,w,h,{r}) api.box(cx,cy,w,h,o) api.circle(x,y,r,o) api.ellipse(x,y,rx,ry,o)
 api.arc(x,y,r,a0,a1,o) api.poly(pts,{close}) api.dot(x,y,r,{k,back}) api.glow(x,y,r,{c})
 api.path(svgD,{x,y,s,rot,k,fill}) any SVG path string, drawn on. Use it to draw anything
 api.shape(name,x,y,size,o) stock icons: heart star drop bolt check cross plus arrow cloud sun moon
   leaf person house bell lock magnifier speech doc cup flask bulb pin phone battery eye dumbbell
   tree wifi gear
 api.ring(n,cx,cy,r) points on a circle; api.pts.circle|wave|poly|star(n,...) + api.morph(a,b,k)
   blend shapes into each other; api.move(pts,x,y,s,rot); api.smooth(pts,close); api.blob(pts,o)
TEXT: api.text(str,x,y,{size,c,weight,align,maxw,k,type,bg,font:'hand'|'mono'|'serif'}) returns its
 box. api.kinetic(str,x,y,{mode:'rise'|'pop'|'drop'|'wave'|'scatter'|'type'|'slide',k,size,hot,t})
 big animated words. api.label(str,x,y,{k}) a pill. api.counter(v,x,y,{k,pre,suf,d,size}) a number
 that counts up. api.say(text,from,to) a caption, 6 words or fewer: a voice will speak it, so
 say the point in plain words.
EXPLAIN (the point of the kit):
 api.callout(text,targetX,targetY,labelX,labelY,{k,c,maxw}) a dot on a part, a line, a label
 api.pin(n,x,y,{k}) numbered marker; api.dim(x1,y1,x2,y2,'text',{k}) measure; api.brace(x1,y1,x2,y2)
 api.scribble(x,y,rx,ry,{k}) circle something; api.underline(x,y,w,{k}); api.highlight(x,y,w,h,{k})
 const A=api.node(x,y,w,h,'name',{icon,k,pop,fill,c}) a box that returns anchors; api.link(A,B,
   {k,label,flow:t,bend,c}) an arrow between two nodes, with dots flowing along it
 api.compare(k,drawBefore,drawAfter,{labels:['Before','After']}) a wipe; api.lens(x,y,r,zoom,fn,{k,
   fx,fy}) a magnifier that redraws fn() zoomed; api.clipRect/clipCircle(..., fn)
 api.timeline([{t:'1969',s:'Moon'},...],x,y,w,{k,vert,len}); api.grid(n,{x,y,w,h,cols,gap}) cells
 api.bars([{label,v,c}],x,y,w,h,{k}) api.lineChart([{v:[..],c,label}],x,y,w,h,{k,area,dots})
 api.donut([{v,c}],cx,cy,r,{k}) api.progress(x,y,w,h,v,{k})
MOTION: api.cam(cx,cy,zoom,roll) moves the camera for everything drawn after it (cx,cy offset from
 centre, call api.cam0() to reset); api.focus(x,y,zoom) centres on a point; api.layer(depth,fn)
 parallax layer; api.shake(t,amp). Easing: api.ease api.eout api.ein api.back api.bounce api.spring(t)
 api.lerp api.clamp api.seg api.noise api.rand api.pulse(t,hz) api.orbit(t,cx,cy,rx,ry,period)
 api.wave(x,t,wl,speed,amp) api.sim(key,init,step,t) a cached physics step.
 api.swarm(n,t,{mode:'drift'|'rise'|'fall'|'orbit'|'burst'|'flock'|'suck',cx,cy,rx,ry,c,glow,k})
 api.along(pts,n,t,{c}) particles flowing along a polyline; api.stars(n,t); api.bg('grid'|'dots'|
 'gradient'|'glow'); api.d3.cam({yaw,pitch,dist,cy}) with api.d3.box|sphere|torus|cyl|cone|helix|
 plane + api.d3.xf(mesh,{rx,ry,rz,x,y,z,s}) + api.d3.solid|wire(mesh,P,{c}) for 3D;
 api.geo.proj({type:'ortho'|'equi',lon,lat,cx,cy,r}) + api.geo.land(P,{only:['FR'],c}) +
 api.geo.route(lon1,lat1,lon2,lat2,P,{k}) + api.geo.pin(lon,lat,P) for maps.
 api.S is a plain object that persists across scenes (share layout between scenes).

EXAMPLE of one scene, to show the calls (not the style; yours should look nothing like it):
=== scene kettle 6 ===
api.look('sketch');
const k = api.seg(t, 0, 1.6), cx = api.w/2, cy = 400;
api.path('M-70 40 L-60 -40 C-60 -70 60 -70 60 -40 L70 40 Z', {x:cx, y:cy, s:2.4, c:'accent', w:5, fill:'accent', k});
api.path('M60 -20 C110 -30 110 30 66 20', {x:cx, y:cy, s:2.4, c:'fg', w:5, k:api.seg(t,1,2)});
api.swarm(40, t, {mode:'rise', cx, cy:cy-200, rx:80, ry:160, c:'a2', size:3});
api.callout('Water heats', cx-60, cy+40, 80, cy+200, {k:api.seg(t,2,3.2)});
api.callout('Steam pushes out', cx+10, cy-200, 300, cy-260, {k:api.seg(t,3,4.2)});
api.focus(cx, cy, api.lerp(1, 1.5, api.ease(api.seg(t,3.5,6))));
api.say('Heat makes steam', 0.4, 5.5);

LOOK (every scene is judged on one frame, so each frame must stand on its own):
- THE HERO IS BIG. 280 to 360 px wide, in the middle band (y 140 to api.h-190). A path drawn about 160 units wide needs
  s of 2 or more. A hero under 240 px wide, or one that still has not finished drawing 2 s in, is a failure.
- THE HERO IS THE THING. Name the nouns of the ask (chicken, lemon, oven; the Settings rows; database, agent) and DRAW
  each one as one big filled silhouette (api.path, filled) plus 2 or 3 detail strokes that make it that thing, or a
  stock api.shape at size 200 or more. A bare circle, blob, box or bar is never a stand-in. Work between a person and
  an agent is drawn as the real artefact in the ask's own words: a phone outline with its real rows written out, a
  week of day tiles with a marker on today, a row of named parts joined by arrows. api.node boxes are for software
  parts only, and each carries an icon. Scene 1 holds to the same bar: no dot, no ring, no thin outline.
- NOTHING SITS ON ANYTHING. A label stays 12 px clear of every line and shape: put it in open space and point at the
  part with api.callout. Stack labels at least 40 px apart. Everything except the caption stays above y=api.h-170.
  When a value changes (0 reps, 8 reps) draw ONE api.counter, never two texts in the same spot.
- SOMETHING MOVES THROUGH THE WHOLE SCENE: a part draws on, a counter climbs, particles flow, the camera drifts in. A
  frame at 2 s must differ from one at 1.4 s. Camera moves are for the drawing: call api.cam0() before any text.
- A thing built from parts (a mug, 330 px wide), the way to draw any object:
  api.path('M-50 -40 L-44 50 Q0 66 44 50 L50 -40 Z', {x:cx, y:cy, s:3.2, c:'fg', w:5, fill:'panel', k});
  api.path('M50 -20 C95 -26 95 28 46 20', {x:cx, y:cy, s:3.2, c:'fg', w:5, k:api.seg(t,0.6,1.4)});
  api.ellipse(cx, cy-120, 150, 24, {c:'accent', fill:'accent', a:0.8, k:api.seg(t,0.3,1)});
  api.swarm(24, t, {mode:'rise', cx, cy:cy-230, rx:60, ry:130, c:'a2'});

DIRECTION.
- Fill the screen. The hero drawing is at least two thirds of the width and sits in the middle band;
  labels are 15 px or bigger (16 to 22 is right), titles 28 to 44. Nothing small, nothing crowded:
  one idea per scene, at most 5 labelled parts.
- Draw the object, not a diagram of boxes: build it from api.path / api.shape / circles and
  polygons so it looks like the thing (a heart, a gear train, a city skyline, a bank statement),
  then label it. Use boxes and links only when the subject really is a system of parts.
- Explain first, decorate second: every frame shows one thing the viewer gets in a glance.
  Build a drawing up part by part. Point at parts with callouts. Zoom into a detail with the camera
  or a lens. Show change as before/after, a move, or a count. Use arrows for flow, braces for groups.
- Unique every time: choose your own metaphor, look and camera plan for this ask. A different run
  of the same ask should look different. No slide layouts, no bullet lists, no title-and-text.
- Move the camera. Push in, pan, pull back, roll a little. Keep one hero shape and carry it from
  scene to scene so the film reads as one move. Hold each idea long enough to read it (2 s minimum).
- Few words on screen (a voice-over speaks them): labels of 1 to 3 words, captions of 6 or fewer.
- Light work: under 400 draw calls a frame, 60 fps on a phone. Use api.shape and api.path for
  objects; keep particle counts under 150.
