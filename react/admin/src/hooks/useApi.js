import { useMemo } from 'react';
import ApiClient from '../ApiClient';
import { useAuth } from '../contexts/AuthContext';

export default function useApi() {
  const { token, api_url, host } = useAuth();
  return useMemo(() => new ApiClient(api_url, token, host), [api_url, token, host]);
}
