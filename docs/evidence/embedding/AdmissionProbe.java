public final class AdmissionProbe {
  private static native void inspect(boolean late);
  public static void main(String[] args) {System.load(args[0]); inspect(args.length>1);}
}
