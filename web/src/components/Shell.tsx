import { Link, useRouterState } from "@tanstack/react-router";
import { REVIEW_STATES, useStore } from "@/lib/store";
import { tap } from "@/lib/haptics";
import { cn } from "@/lib/utils";

const NAV = [
  { to: "/", label: "Wall" },
  { to: "/sources", label: "Sources" },
  { to: "/history", label: "History" },
  { to: "/profiles", label: "Balance" },
  { to: "/power", label: "Power" },
  { to: "/settings", label: "Setup" },
] as const;

function NavStrip({ pathname, className }: { pathname: string; className?: string }) {
  const activeIndex = Math.max(
    0,
    NAV.findIndex((n) => (n.to === "/" ? pathname === "/" : pathname.startsWith(n.to))),
  );
  return (
    <nav className={cn("placard-sunk relative isolate grid grid-cols-6 overflow-hidden p-0.5", className)}>
      <span
        aria-hidden
        className="absolute inset-y-0.5 left-0.5 -z-10 rounded-[5px] bg-foreground transition-transform duration-300 [transition-timing-function:var(--ease-snap)]"
        style={{ width: "calc((100% - 4px) / 6)", transform: `translateX(${activeIndex * 100}%)` }}
      />
      {NAV.map(({ to, label }, i) => (
        <Link
          key={to}
          to={to}
          onClick={() => tap()}
          className={cn(
            "num press z-0 truncate px-1 py-2.5 text-center text-[10px] uppercase tracking-[0.1em] transition-colors duration-300",
            i === activeIndex ? "text-background" : "text-muted-foreground hover:text-foreground",
          )}
        >
          {label}
        </Link>
      ))}
    </nav>
  );
}

export function Shell({ children }: { children: React.ReactNode }) {
  const { review, setReview } = useStore();
  const pathname = useRouterState({ select: (s) => s.location.pathname });

  return (
    <div className="relative flex min-h-[100dvh] flex-col overflow-x-clip bg-background text-foreground">
      {/* The room, lit by whatever the wall is showing. Dark when the wall is dark. */}
      <div aria-hidden className="pointer-events-none fixed inset-0 z-0">
        <div className="roomlight breathing absolute inset-0" />
      </div>

      <header className="relative z-20 pt-[env(safe-area-inset-top)]">
        <div className="mx-auto flex w-full max-w-3xl items-center gap-3 px-5 pb-2 pt-5">
          <Link to="/" onClick={() => tap()} className="group min-w-0">
            <span className="display-wide block truncate text-[17px] uppercase leading-none text-foreground">
              Album&nbsp;Art&nbsp;Matrix
            </span>
            <span className="eyebrow mt-1.5 block">
              3&times;3 &middot; hub75 &middot; p2.5 &middot; simulation
            </span>
          </Link>

          <div className="relative ml-auto shrink-0">
            <select
              value={review}
              onChange={(e) => {
                tap();
                setReview(e.target.value as never);
              }}
              aria-label="Design review state"
              className={cn(
                "num max-w-[10rem] appearance-none rounded-md border bg-transparent px-2.5 py-1.5 pr-6 text-[10px] uppercase tracking-[0.08em] outline-none",
                review !== "off"
                  ? "border-warning/50 text-warning"
                  : "border-border text-muted-foreground",
              )}
            >
              {REVIEW_STATES.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.label}
                </option>
              ))}
            </select>
            <span className="pointer-events-none absolute right-2 top-1/2 -translate-y-1/2 text-[8px] text-muted-foreground">
              ▾
            </span>
          </div>
        </div>

        {/* Desktop: the strip lives under the masthead. */}
        <div className="mx-auto hidden w-full max-w-3xl px-5 pb-1 pt-2 md:block">
          <NavStrip pathname={pathname} />
        </div>

        {review !== "off" && (
          <div className="mx-auto w-full max-w-3xl px-5 pt-2">
            <p className="num border border-warning/50 px-3 py-1.5 text-[10px] uppercase tracking-[0.1em] text-warning">
              review mode &middot; forced into &ldquo;{REVIEW_STATES.find((s) => s.id === review)?.label}&rdquo; &middot; not a live reading
            </p>
          </div>
        )}
      </header>

      <main className="relative z-10 mx-auto w-full max-w-3xl flex-1 px-5 pb-8 pt-3">{children}</main>

      <footer className="relative z-10 mx-auto w-full max-w-3xl px-5 pb-28 pt-3 md:pb-8">
        <p className="eyebrow leading-relaxed normal-case tracking-[0.06em]">
          Simulation and circuit models only. Nine 64&times;64 HUB75 P2.5 panels, 3&times;3, 480 mm on a side. Ten
          panels are on the bench; the wall is not yet assembled, and nothing here is a measurement of it.
        </p>
      </footer>

      {/* Phone: the strip floats at the bottom, in reach of a thumb. */}
      <div className="fixed inset-x-0 bottom-0 z-30 px-4 pb-[max(env(safe-area-inset-bottom),0.9rem)] md:hidden">
        <div className="pointer-events-none absolute inset-x-0 bottom-0 h-24 bg-gradient-to-t from-background via-background/80 to-transparent" />
        <div className="relative mx-auto max-w-md">
          <NavStrip pathname={pathname} className="bg-background/95" />
        </div>
      </div>
    </div>
  );
}
