/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{js,ts,jsx,tsx}'],
  theme: {
    extend: {
      colors: {
        kennel: {
          ink: '#1b1715',
          paper: '#f6f0e4',
          maroon: '#761d32',
          wine: '#4d1222',
          gold: '#e5a93d',
          cream: '#fff9ee',
          green: '#2f634c',
        },
      },
      fontFamily: {
        display: ['Arial Black', 'Arial', 'sans-serif'],
        body: ['Inter', 'ui-sans-serif', 'system-ui', 'sans-serif'],
      },
      boxShadow: {
        card: '0 18px 50px rgba(38, 18, 23, 0.12)',
      },
    },
  },
  plugins: [],
}
