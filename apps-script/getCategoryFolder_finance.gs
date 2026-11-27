// GANTI fungsi getCategoryFolder_ (baris 49-66) dengan ini:
function getCategoryFolder_(category, subFolder) {
  const root = getRootFolder_();

  if (category === "badge-foto") {
    const fotoRoot = getOrCreateFolder_(root, "Foto Karyawan");
    const safeSub = String(subFolder || "").trim().replace(/\//g, "-") || "Lainnya";
    return getOrCreateFolder_(fotoRoot, safeSub);
  }

  if (category === "kontrak-karyawan") {
    return getOrCreateFolder_(root, "Kontrak Karyawan");
  }

  const monthFolder = Utilities.formatDate(new Date(), Session.getScriptTimeZone() || "GMT+8", "yyyy-MM");

  // SmartFin: dokumen invoice, faktur pajak, jaminan uang muka
  if (category === "finance") {
    return getOrCreateFolder_(getOrCreateFolder_(root, "finance"), monthFolder);
  }

  const safe = category === "reports" ? "reports" : "photos";
  const catFolder = getOrCreateFolder_(root, safe);
  return getOrCreateFolder_(catFolder, monthFolder);
}

// DAN di handleUpload_, GANTI baris:
//   file.setSharing(DriveApp.Access.ANYONE_WITH_LINK, DriveApp.Permission.VIEW);
// dengan:
//   if (category !== "finance") {
//     file.setSharing(DriveApp.Access.ANYONE_WITH_LINK, DriveApp.Permission.VIEW);
//   }
