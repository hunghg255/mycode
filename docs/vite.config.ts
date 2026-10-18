import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// The site reads the screenshots in docs/screenshots and the app icon in
// resources/, so the dev server may serve files from the whole repository.
export default defineConfig({
  base: './',
  plugins: [react()],
  server: { fs: { allow: ['..'] } },
})
