using System;
using System.Runtime.InteropServices;
public static class DiagUsb {
 [DllImport("LIBUSB_PATH", CallingConvention=CallingConvention.Cdecl)] public static extern int libusb_init(out IntPtr ctx);
 [DllImport("LIBUSB_PATH", CallingConvention=CallingConvention.Cdecl)] public static extern IntPtr libusb_open_device_with_vid_pid(IntPtr ctx, ushort vid, ushort pid);
 [DllImport("LIBUSB_PATH", CallingConvention=CallingConvention.Cdecl)] public static extern IntPtr libusb_get_device(IntPtr handle);
 [DllImport("LIBUSB_PATH", CallingConvention=CallingConvention.Cdecl)] public static extern int libusb_get_active_config_descriptor(IntPtr dev, out IntPtr config);
 [DllImport("LIBUSB_PATH", CallingConvention=CallingConvention.Cdecl)] public static extern void libusb_free_config_descriptor(IntPtr config);
 [DllImport("LIBUSB_PATH", CallingConvention=CallingConvention.Cdecl)] public static extern int libusb_claim_interface(IntPtr handle, int iface);
 [DllImport("LIBUSB_PATH", CallingConvention=CallingConvention.Cdecl)] public static extern int libusb_release_interface(IntPtr handle, int iface);
 [DllImport("LIBUSB_PATH", CallingConvention=CallingConvention.Cdecl)] public static extern int libusb_bulk_transfer(IntPtr handle, byte ep, byte[] data, int len, out int transferred, uint timeout);
 [DllImport("LIBUSB_PATH", CallingConvention=CallingConvention.Cdecl)] public static extern void libusb_close(IntPtr handle);
 [DllImport("LIBUSB_PATH", CallingConvention=CallingConvention.Cdecl)] public static extern void libusb_exit(IntPtr ctx);
 public static int[] Endpoints(IntPtr handle) {
  IntPtr config; int rc=libusb_get_active_config_descriptor(libusb_get_device(handle),out config);
  if(rc<0) throw new Exception("descriptor error "+rc);
  try {
   int count=Marshal.ReadByte(config,4); IntPtr interfaces=Marshal.ReadIntPtr(config,16);
   for(int i=0;i<count;i++) {
    IntPtr iface=IntPtr.Add(interfaces,i*16); IntPtr alt=Marshal.ReadIntPtr(iface); int alts=Marshal.ReadInt32(iface,8);
    for(int a=0;a<alts;a++) {
     IntPtr desc=IntPtr.Add(alt,a*40); int n=Marshal.ReadByte(desc,4); IntPtr eps=Marshal.ReadIntPtr(desc,16); int input=-1,output=-1;
     for(int e=0;e<n;e++) { IntPtr ep=IntPtr.Add(eps,e*32); int address=Marshal.ReadByte(ep,2); if((Marshal.ReadByte(ep,3)&3)!=2) continue; if((address&128)!=0) input=address; else output=address; }
     if(input>=0 && output>=0) return new int[]{Marshal.ReadByte(desc,2),input,output};
    }
   }
   throw new Exception("No bulk endpoint pair");
  } finally { libusb_free_config_descriptor(config); }
 }
}