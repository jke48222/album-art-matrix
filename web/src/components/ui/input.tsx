import * as React from "react";

import { cn } from "@/lib/utils";

const Input = React.forwardRef<HTMLInputElement, React.ComponentProps<"input">>(
  ({ className, type, ...props }, ref) => {
    return (
      <input
        type={type}
        className={cn(
          "num flex h-9 w-full rounded-md border border-border bg-surface-sunk px-3 py-1 text-xs text-foreground placeholder:text-muted-foreground/60 focus-visible:outline-none focus-visible:border-foreground/40 disabled:cursor-not-allowed disabled:opacity-50",
          className,
        )}
        ref={ref}
        {...props}
      />
    );
  },
);
Input.displayName = "Input";

export { Input };
