"use client";

// Scheduled export to Google Drive: settings, last run and "export now".

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api, unwrap, type Schemas } from "./client";

export type DriveBackup = Schemas["DriveBackup"];
export type DriveBackupInput = Schemas["DriveBackupInput"];

const key = ["drive-backup"] as const;

/** Polls every 2 seconds while a backup runs so progress and the outcome show without a reload. */
export function useDriveBackup() {
  return useQuery({
    queryKey: key,
    queryFn: () => unwrap(api.GET("/backups/drive")),
    refetchInterval: (q) => (q.state.data?.running ? 2000 : 30_000),
  });
}

export function useSaveDriveBackup() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: DriveBackupInput) => unwrap(api.PUT("/backups/drive", { body })),
    onSuccess: (b) => qc.setQueryData(key, b),
  });
}

export function useRunDriveBackup() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: () => unwrap(api.POST("/backups/drive/run")),
    onSuccess: (b) => qc.setQueryData(key, b),
    // A 409 means another run holds the lease (or nothing is set): show what is.
    onError: () => qc.invalidateQueries({ queryKey: key }),
  });
}
