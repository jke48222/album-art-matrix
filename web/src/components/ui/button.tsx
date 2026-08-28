import * as React from "react";
import { Slot } from "@radix-ui/react-slot";
import { cva, type VariantProps } from "class-variance-authority";

import { cn } from "@/lib/utils";

const buttonVariants = cva(
  "num press inline-flex items-center justify-center gap-2 whitespace-nowrap rounded-md uppercase tracking-[0.1em] cursor-pointer transition-colors focus-visible:outline-none disabled:pointer-events-none disabled:opacity-40 disabled:cursor-not-allowed [&_svg]:pointer-events-none [&_svg]:size-3.5 [&_svg]:shrink-0",
  {
    variants: {
      variant: {
        default: "border border-primary bg-primary text-primary-foreground hover:opacity-90",
        destructive: "border border-primary bg-transparent text-primary hover:bg-primary hover:text-primary-foreground",
        outline: "border border-border bg-transparent text-muted-foreground hover:border-foreground/40 hover:text-foreground",
        secondary: "border border-border bg-transparent text-muted-foreground hover:border-foreground/40 hover:text-foreground",
        ghost: "text-muted-foreground hover:text-foreground",
        link: "text-foreground underline-offset-4 hover:underline normal-case tracking-normal",
      },
      size: {
        default: "h-9 px-4 py-2 text-[11px]",
        sm: "h-8 rounded-md px-3 text-[10px]",
        lg: "h-10 rounded-md px-8 text-[11px]",
        icon: "h-8 w-8",
      },
    },
    defaultVariants: {
      variant: "default",
      size: "default",
    },
  },
);

export interface ButtonProps
  extends React.ButtonHTMLAttributes<HTMLButtonElement>, VariantProps<typeof buttonVariants> {
  asChild?: boolean;
}

const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant, size, asChild = false, ...props }, ref) => {
    const Comp = asChild ? Slot : "button";
    return (
      <Comp className={cn(buttonVariants({ variant, size, className }))} ref={ref} {...props} />
    );
  },
);
Button.displayName = "Button";

export { Button, buttonVariants };
