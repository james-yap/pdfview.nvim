#set page(width: 460pt, height: 620pt, margin: (x: 28pt, y: 30pt), numbering: "1")
#set text(font: "New Computer Modern", size: 12pt)
#set par(justify: true, leading: 0.62em)
#set heading(numbering: "1.")
#show heading: set block(above: 1.2em, below: 0.7em)
#set math.equation(numbering: "(1)")

#align(center)[
  #text(size: 19pt, weight: "bold")[A Pendulum in a Moving Lift]
  #v(-0.4em)
  #text(size: 11pt, style: "italic")[Lecture notes · Classical Mechanics, week 3]
]

= The simple pendulum

A small bob of mass $m$ hangs from a light string of length $l$. When the
string makes an angle $theta$ with the vertical, gravity pulls the bob back
towards the bottom of its swing. Newton's second law along the arc gives

$ m l (d^2 theta)/(d t^2) = -m g sin theta. $ <eq-motion>

For small swings $sin theta approx theta$, so the motion is simple harmonic:

$ theta(t) = theta_0 cos(omega t + phi), quad omega = sqrt(g/l). $ <eq-shm>

The period $T = 2 pi sqrt(l\/g)$ does not depend on the mass of the bob or on
the size of the swing, which is why pendulums made such good clocks.

#figure(
  box(width: 150pt, height: 120pt, {
    place(dx: 75pt, dy: 0pt, line(start: (0pt, 0pt), end: (0pt, 110pt), stroke: (dash: "dashed", thickness: 0.6pt)))
    place(dx: 75pt, dy: 0pt, line(start: (0pt, 0pt), end: (40pt, 92pt), stroke: 1pt))
    place(dx: 107pt, dy: 84pt, circle(radius: 8pt, fill: rgb("#3b6ea8")))
    place(dx: 50pt, dy: -6pt, line(start: (0pt, 0pt), end: (50pt, 0pt), stroke: 2pt))
    place(dx: 82pt, dy: 30pt, text(size: 11pt)[$theta$])
    place(dx: 104pt, dy: 40pt, text(size: 11pt)[$l$])
  }),
  caption: [A simple pendulum of length $l$, displaced by an angle $theta$.],
)

= Inside a lift

Now put the pendulum inside a lift that accelerates upwards with
acceleration $a(t)$. In the frame of the lift every object feels an extra
inertial force $-m a(t)$, so the bob behaves as if gravity were

$ g_"eff" (t) = g + a(t). $ <eq-geff>

The equation of motion keeps its form, with $g$ replaced by $g_"eff"$:

$ (d^2 theta)/(d t^2) = -(g + a(t))/l sin theta. $

When the lift moves at constant speed, $a = 0$ and nothing changes. While it
speeds up going up, $g_"eff" > g$ and the pendulum swings faster; while it
slows down, $g_"eff" < g$ and the swings stretch out.

= How big is the effect?

A real lift accelerates at about $a approx 1 "m/s"^2$, roughly a tenth of $g$.
For small $a$ the period changes by

$ (Delta T)/T approx -a/(2 g) approx -5 %, $

small but easy to measure with a phone: film the pendulum and count the
swings while the lift starts and stops.

= A measurement

We hung a $0.80 "m"$ pendulum in an office lift and timed ten swings in each
part of the ride. The lift took about two seconds to reach full speed.

#figure(
  table(
    columns: 3,
    align: (left, center, center),
    stroke: none,
    table.hline(),
    [*Part of the ride*], [*Ten swings (s)*], [*$g_"eff"$ (m/s#super[2])*],
    table.hline(stroke: 0.5pt),
    [At rest], [17.94], [9.81],
    [Starting upwards], [17.10], [10.80],
    [Constant speed], [17.95], [9.80],
    [Stopping at the top], [18.88], [8.86],
    table.hline(),
  ),
  caption: [Ten-swing times and the effective gravity they imply.],
)

The swings speed up when the lift starts and slow down when it stops, just as
@eq-geff predicts. At constant speed the period is the same as at rest: a
pendulum cannot tell a steadily moving lift from the ground.


= Exercises

+ A pendulum of length $1 "m"$ hangs in a lift. Find its period when the lift
  accelerates upwards at $2 "m/s"^2$.
+ What happens to the pendulum if the lift cable breaks and the lift falls
  freely?
+ Show that the result for $Delta T \/ T$ follows from @eq-shm and @eq-geff.
