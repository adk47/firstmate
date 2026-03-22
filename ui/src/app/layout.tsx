import type { Metadata } from 'next';
import Link from 'next/link';
import {
  Activity,
  Bot,
  Shield,
  FileText,
  DollarSign,
  AlertTriangle,
  LayoutDashboard,
} from 'lucide-react';
import './globals.css';

export const metadata: Metadata = {
  title: 'HYDRA Control',
  description: 'Multi-agent orchestration management dashboard',
};

const navItems = [
  { href: '/', label: 'Dashboard', icon: LayoutDashboard },
  { href: '/policies', label: 'Policies', icon: Shield },
  { href: '/audit', label: 'Audit Log', icon: FileText },
  { href: '/costs', label: 'Costs', icon: DollarSign },
  { href: '/alerts', label: 'Alerts', icon: AlertTriangle },
];

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" className="dark">
      <body className="min-h-screen bg-gray-950 text-gray-100">
        <div className="flex h-screen">
          {/* Sidebar */}
          <aside className="w-64 bg-gray-900 border-r border-gray-800 flex flex-col">
            <div className="p-6 border-b border-gray-800">
              <div className="flex items-center gap-3">
                <div className="w-10 h-10 bg-hydra-700 rounded-lg flex items-center justify-center">
                  <Bot className="w-6 h-6 text-white" />
                </div>
                <div>
                  <h1 className="text-lg font-bold text-white tracking-tight">HYDRA</h1>
                  <p className="text-xs text-gray-500">Control Plane</p>
                </div>
              </div>
            </div>

            <nav className="flex-1 p-4 space-y-1">
              {navItems.map((item) => (
                <Link
                  key={item.href}
                  href={item.href}
                  className="flex items-center gap-3 px-3 py-2.5 rounded-lg text-gray-400 hover:text-white hover:bg-gray-800 transition-colors duration-150"
                >
                  <item.icon className="w-5 h-5" />
                  <span className="text-sm font-medium">{item.label}</span>
                </Link>
              ))}
            </nav>

            <div className="p-4 border-t border-gray-800">
              <div className="flex items-center gap-2 text-xs text-gray-600">
                <Activity className="w-3 h-3" />
                <span>hydra.muso.ai</span>
              </div>
            </div>
          </aside>

          {/* Main content */}
          <main className="flex-1 overflow-y-auto">
            <div className="p-8">
              {children}
            </div>
          </main>
        </div>
      </body>
    </html>
  );
}
