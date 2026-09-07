import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import { HostPage } from './pages/host-page'
import { PrintPage } from './pages/print-page'
import { PunterPage } from './pages/punter-page'
import { ScreenPage } from './pages/screen-page'

export function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<PunterPage />} />
        <Route path="/host" element={<HostPage />} />
        <Route path="/host/print" element={<PrintPage />} />
        <Route path="/screen" element={<ScreenPage />} />
        <Route path="*" element={<Navigate replace to="/" />} />
      </Routes>
    </BrowserRouter>
  )
}
