/** @type {import('tailwindcss').Config} */
export default {
    darkMode: ["class"],
    content: [
        "./index.html",
        "./src/**/*.{js,ts,jsx,tsx}",
        "./node_modules/@mriqbox/ui-kit/dist/**/*.{js,mjs}"
    ],
    theme: {
        extend: {
            colors: {
                border: "hsl(var(--border))",
                input: "hsl(var(--input))",
                ring: "hsl(var(--ring))",
                background: "hsl(var(--background))",
                foreground: "hsl(var(--foreground))",
                primary: {
                    DEFAULT: "hsl(160, 100%, 45%)", // MRI Neon Green
                    foreground: "hsl(240, 10%, 4%)",
                },
                secondary: {
                    DEFAULT: "hsl(240, 5%, 15%)",
                    foreground: "hsl(0, 0%, 98%)",
                },
                destructive: {
                    DEFAULT: "hsl(0, 62.8%, 30.6%)",
                    foreground: "hsl(0, 0%, 98%)",
                },
                muted: {
                    DEFAULT: "hsl(240, 5%, 15%)",
                    foreground: "hsl(240, 5%, 60%)",
                },
                accent: {
                    DEFAULT: "hsl(240, 5%, 15%)",
                    foreground: "hsl(0, 0%, 98%)",
                },
                popover: {
                    DEFAULT: "hsl(240, 10%, 6%)",
                    foreground: "hsl(0, 0%, 98%)",
                },
                card: {
                    DEFAULT: "hsl(240, 10%, 6%)",
                    foreground: "hsl(0, 0%, 98%)",
                },
            },
            fontFamily: {
                sans: ["Inter", "ui-sans-serif", "system-ui", "-apple-system", "sans-serif"],
            },
            borderRadius: {
                lg: "var(--radius)",
                md: "calc(var(--radius) - 2px)",
                sm: "calc(var(--radius) - 4px)",
            },
        },
    },
    plugins: [],
}

