/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    './src/**/*.{js,ts,jsx,tsx,mdx}',
  ],
  darkMode: 'class',
  theme: {
    extend: {
      colors: {
        hydra: {
          50: '#eef9ff',
          100: '#d9f1ff',
          200: '#bce7ff',
          300: '#8ed9ff',
          400: '#59c2ff',
          500: '#33a3ff',
          600: '#1b83f5',
          700: '#146ce1',
          800: '#1757b6',
          900: '#194a8f',
          950: '#142e57',
        },
      },
    },
  },
  plugins: [
    require('@tailwindcss/forms'),
  ],
};
