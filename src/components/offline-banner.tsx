interface OfflineBannerProps {
  online: boolean
}

export function OfflineBanner({ online }: OfflineBannerProps) {
  if (online) return null
  return (
    <div className="offline-banner" role="status">
      <span aria-hidden="true">●</span>
      Offline — scores are frozen and actions are disabled until you reconnect.
    </div>
  )
}
