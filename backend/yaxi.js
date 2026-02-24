import { RoutexClient } from 'routex-client'

export function makeClient() {
  // default is production per docs
  return new RoutexClient()
}
