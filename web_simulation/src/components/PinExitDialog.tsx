import React, { useEffect, useState } from 'react';
import { Delete, Lock, ShieldAlert, X } from 'lucide-react';

interface PinExitDialogProps {
  isOpen: boolean;
  expectedPin: string;
  onCancel: () => void;
  onSuccess: () => void;
}

export const PinExitDialog: React.FC<PinExitDialogProps> = ({
  isOpen,
  expectedPin,
  onCancel,
  onSuccess,
}) => {
  const [digits, setDigits] = useState<string>('');
  const [error, setError] = useState<string | null>(null);
  const [attempts, setAttempts] = useState<number>(0);
  const [shakeKey, setShakeKey] = useState<number>(0);

  useEffect(() => {
    if (!isOpen) {
      setDigits('');
      setError(null);
    }
  }, [isOpen]);

  useEffect(() => {
    if (!isOpen) return;

    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key >= '0' && e.key <= '9') {
        e.preventDefault();
        handleDigitPress(e.key);
      } else if (e.key === 'Backspace') {
        e.preventDefault();
        setDigits((prev) => prev.slice(0, -1));
        setError(null);
      } else if (e.key === 'Escape') {
        e.preventDefault();
        onCancel();
      }
    };

    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  });

  const verifyPin = (candidate: string) => {
    if (candidate === expectedPin) {
      setDigits('');
      setError(null);
      setAttempts(0);
      onSuccess();
    } else {
      const nextAttempts = attempts + 1;
      setAttempts(nextAttempts);
      setError(`Incorrect PIN (Attempt ${nextAttempts}). Pass Mode remains locked.`);
      setShakeKey((k) => k + 1);
      setTimeout(() => setDigits(''), 260);
    }
  };

  const handleDigitPress = (digit: string) => {
    if (digits.length >= 4) return;
    const next = digits + digit;
    setDigits(next);
    setError(null);
    if (next.length === 4) {
      setTimeout(() => verifyPin(next), 120);
    }
  };

  if (!isOpen) return null;

  const keypad = ['1', '2', '3', '4', '5', '6', '7', '8', '9'];

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-slate-950/70 backdrop-blur-sm p-4"
      role="dialog"
      aria-modal="true"
      aria-labelledby="pin-dialog-title"
    >
      <div
        key={shakeKey}
        className={`w-full max-w-sm rounded-2xl bg-white border border-slate-200 shadow-2xl p-6 ${
          error ? 'animate-shake' : ''
        }`}
      >
        <div className="flex items-start justify-between gap-4">
          <div className="flex items-center gap-3">
            <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-slate-900 text-white shrink-0">
              <Lock className="h-5 w-5" />
            </div>
            <div>
              <h2 id="pin-dialog-title" className="text-base font-bold text-slate-900">
                Lecturer PIN Required
              </h2>
              <p className="text-xs text-slate-500">
                Enter the lecturer PIN configured in Teacher Monitor.
              </p>
            </div>
          </div>
          <button
            type="button"
            onClick={onCancel}
            className="min-h-[40px] min-w-[40px] flex items-center justify-center rounded-lg text-slate-400 hover:text-slate-700 hover:bg-slate-100 transition-colors"
            aria-label="Stay in Student Pass Mode"
          >
            <X className="h-5 w-5" />
          </button>
        </div>

        <p className="mt-4 text-xs leading-relaxed text-slate-600">
          Student Pass Mode is locked to prevent back-navigation or app switching while the device is passed desk-to-desk.
        </p>

        {/* 4-dot PIN indicator */}
        <div className="my-6 flex items-center justify-center gap-4" aria-label={`Entered ${digits.length} of 4 digits`}>
          {[0, 1, 2, 3].map((idx) => {
            const filled = idx < digits.length;
            return (
              <div
                key={idx}
                className={`h-4 w-4 rounded-full border-2 transition-all duration-150 ${
                  error
                    ? 'border-red-500 bg-red-100'
                    : filled
                    ? 'border-slate-900 bg-slate-900 scale-110'
                    : 'border-slate-300 bg-slate-50'
                }`}
              />
            );
          })}
        </div>

        {error && (
          <div className="mb-4 flex items-center gap-2 rounded-lg border border-red-200 bg-red-50 px-3 py-2 text-xs font-medium text-red-700">
            <ShieldAlert className="h-4 w-4 shrink-0" />
            <span>{error}</span>
          </div>
        )}

        {/* Touch-friendly 44px+ keypad */}
        <div className="grid grid-cols-3 gap-2.5">
          {keypad.map((num) => (
            <button
              key={num}
              type="button"
              onClick={() => handleDigitPress(num)}
              className="h-12 rounded-xl border border-slate-200 bg-slate-50 text-lg font-semibold text-slate-900 tabular-nums hover:bg-slate-100 active:scale-[0.97] transition-all focus-visible:outline-2 focus-visible:outline-slate-900"
            >
              {num}
            </button>
          ))}
          <button
            type="button"
            onClick={onCancel}
            className="h-12 rounded-xl border border-slate-200 bg-white text-xs font-medium text-slate-600 hover:bg-slate-50 transition-colors"
          >
            Cancel
          </button>
          <button
            type="button"
            onClick={() => handleDigitPress('0')}
            className="h-12 rounded-xl border border-slate-200 bg-slate-50 text-lg font-semibold text-slate-900 tabular-nums hover:bg-slate-100 active:scale-[0.97] transition-all"
          >
            0
          </button>
          <button
            type="button"
            onClick={() => {
              setDigits((prev) => prev.slice(0, -1));
              setError(null);
            }}
            aria-label="Delete last digit"
            className="h-12 rounded-xl border border-slate-200 bg-white flex items-center justify-center text-slate-600 hover:bg-slate-50 transition-colors"
          >
            <Delete className="h-5 w-5" />
          </button>
        </div>
      </div>
    </div>
  );
};
