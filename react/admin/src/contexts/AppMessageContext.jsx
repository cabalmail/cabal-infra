import { createContext, useContext } from 'react';

const AppMessageContext = createContext(null);

export function useAppMessage() {
  const ctx = useContext(AppMessageContext);
  if (!ctx) {
    throw new Error('useAppMessage must be used within an AppMessageProvider');
  }
  return ctx;
}

export default AppMessageContext;
