/**
 * Power / wiring circuit model. Modelled, not measured.
 *
 * Copper resistance at 20 C, per conductor:
 *   14 AWG: 8.286 mOhm/m
 *   18 AWG: 20.95 mOhm/m
 *
 * The wall is fed in sections: a trunk run carries one section's current out and
 * back (round trip), through a fuse and clip, then a short 18 AWG harness feeds
 * each panel.
 */

export const AWG_MOHM_PER_M: Record<14 | 18, number> = { 14: 8.286, 18: 20.95 };

export interface PowerInputs {
  panels: number;
  panelsPerSection: number;
  ampsPerPanel: number;
  trunkLengthM: number;
  trunkAwg: 14 | 18;
  fuseClipMilliOhm: number;
  harnessLengthM: number;
  supplyVolts: number;
}

export interface PowerOutputs {
  totalAmps: number;
  sectionAmps: number;
  sections: number;
  trunkOhms: number;
  harnessOhms: number;
  fuseOhms: number;
  trunkDrop: number;
  harnessDrop: number;
  fuseDrop: number;
  totalDrop: number;
  panelVolts: number;
  requiredTrim: number;
  warning: boolean;
}

export const DEFAULT_POWER: PowerInputs = {
  panels: 9,
  panelsPerSection: 3,
  ampsPerPanel: 4.0,
  trunkLengthM: 1.0,
  trunkAwg: 14,
  fuseClipMilliOhm: 7,
  harnessLengthM: 0.4,
  supplyVolts: 5.0,
};

export function computePower(i: PowerInputs): PowerOutputs {
  const totalAmps = i.panels * i.ampsPerPanel;
  const perSection = Math.max(1, Math.min(i.panelsPerSection, i.panels));
  const sections = Math.ceil(i.panels / perSection);
  const sectionAmps = perSection * i.ampsPerPanel;

  const trunkOhms = (AWG_MOHM_PER_M[i.trunkAwg] / 1000) * i.trunkLengthM * 2; // out and back
  const harnessOhms = (AWG_MOHM_PER_M[18] / 1000) * i.harnessLengthM;
  const fuseOhms = i.fuseClipMilliOhm / 1000;

  const trunkDrop = sectionAmps * trunkOhms;
  const fuseDrop = sectionAmps * fuseOhms;
  const harnessDrop = i.ampsPerPanel * harnessOhms;
  const totalDrop = trunkDrop + fuseDrop + harnessDrop;

  const panelVolts = i.supplyVolts - totalDrop;
  const requiredTrim = 5.0 + totalDrop;

  return {
    totalAmps,
    sectionAmps,
    sections,
    trunkOhms,
    harnessOhms,
    fuseOhms,
    trunkDrop,
    harnessDrop,
    fuseDrop,
    totalDrop,
    panelVolts,
    requiredTrim,
    warning: panelVolts < 4.9,
  };
}
