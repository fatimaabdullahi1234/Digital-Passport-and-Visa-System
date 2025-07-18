;; Border Crossing Validation Contract
;; Verifies traveler identity and documents at immigration checkpoints

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u300))
(define-constant ERR-CROSSING-NOT-FOUND (err u301))
(define-constant ERR-INVALID-INPUT (err u302))
(define-constant ERR-DOCUMENT-INVALID (err u303))
(define-constant ERR-ALREADY-PROCESSED (err u304))

;; Data Variables
(define-data-var next-crossing-id uint u1)
(define-data-var contract-active bool true)

;; Data Maps
(define-map border-crossings
  { crossing-id: uint }
  {
    passport-id: uint,
    visa-id: (optional uint),
    checkpoint-id: (string-ascii 50),
    country: (string-ascii 50),
    crossing-type: (string-ascii 10),
    timestamp: uint,
    immigration-officer: principal,
    status: (string-ascii 20),
    notes: (optional (string-ascii 200)),
    biometric-hash: (optional (buff 32))
  }
)

(define-map authorized-checkpoints
  { checkpoint-id: (string-ascii 50) }
  {
    country: (string-ascii 50),
    location: (string-ascii 100),
    active: bool
  }
)

(define-map immigration-officers
  { officer: principal }
  {
    authorized: bool,
    checkpoint-id: (string-ascii 50),
    badge-number: (string-ascii 20)
  }
)

(define-map traveler-status
  { passport-id: uint }
  {
    current-country: (string-ascii 50),
    entry-date: uint,
    status: (string-ascii 20)
  }
)

;; Authorization Functions
(define-public (add-checkpoint
  (checkpoint-id (string-ascii 50))
  (country (string-ascii 50))
  (location (string-ascii 100))
)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (ok (map-set authorized-checkpoints
      { checkpoint-id: checkpoint-id }
      {
        country: country,
        location: location,
        active: true
      }
    ))
  )
)

(define-public (add-immigration-officer
  (officer principal)
  (checkpoint-id (string-ascii 50))
  (badge-number (string-ascii 20))
)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (is-some (map-get? authorized-checkpoints { checkpoint-id: checkpoint-id })) ERR-INVALID-INPUT)
    (ok (map-set immigration-officers
      { officer: officer }
      {
        authorized: true,
        checkpoint-id: checkpoint-id,
        badge-number: badge-number
      }
    ))
  )
)

;; Border Crossing Functions
(define-public (process-entry
  (passport-id uint)
  (visa-id (optional uint))
  (checkpoint-id (string-ascii 50))
  (biometric-hash (optional (buff 32)))
)
  (let
    (
      (crossing-id (var-get next-crossing-id))
      (current-block-height block-height)
      (officer-info (unwrap! (map-get? immigration-officers { officer: tx-sender }) ERR-NOT-AUTHORIZED))
      (checkpoint-info (unwrap! (map-get? authorized-checkpoints { checkpoint-id: checkpoint-id }) ERR-INVALID-INPUT))
    )
    (asserts! (var-get contract-active) ERR-NOT-AUTHORIZED)
    (asserts! (get authorized officer-info) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get checkpoint-id officer-info) checkpoint-id) ERR-NOT-AUTHORIZED)
    (asserts! (get active checkpoint-info) ERR-INVALID-INPUT)

    ;; Verify passport validity (would call passport contract in real implementation)
    ;; For now, assume passport is valid if ID > 0
    (asserts! (> passport-id u0) ERR-DOCUMENT-INVALID)

    ;; Verify visa if required (would call visa contract in real implementation)
    (match visa-id
      vid (asserts! (> vid u0) ERR-DOCUMENT-INVALID)
      true
    )

    (map-set border-crossings
      { crossing-id: crossing-id }
      {
        passport-id: passport-id,
        visa-id: visa-id,
        checkpoint-id: checkpoint-id,
        country: (get country checkpoint-info),
        crossing-type: "entry",
        timestamp: current-block-height,
        immigration-officer: tx-sender,
        status: "approved",
        notes: none,
        biometric-hash: biometric-hash
      }
    )

    (map-set traveler-status
      { passport-id: passport-id }
      {
        current-country: (get country checkpoint-info),
        entry-date: current-block-height,
        status: "present"
      }
    )

    (var-set next-crossing-id (+ crossing-id u1))
    (ok crossing-id)
  )
)

(define-public (process-exit
  (passport-id uint)
  (checkpoint-id (string-ascii 50))
  (biometric-hash (optional (buff 32)))
)
  (let
    (
      (crossing-id (var-get next-crossing-id))
      (current-block-height block-height)
      (officer-info (unwrap! (map-get? immigration-officers { officer: tx-sender }) ERR-NOT-AUTHORIZED))
      (checkpoint-info (unwrap! (map-get? authorized-checkpoints { checkpoint-id: checkpoint-id }) ERR-INVALID-INPUT))
      (traveler-info (map-get? traveler-status { passport-id: passport-id }))
    )
    (asserts! (var-get contract-active) ERR-NOT-AUTHORIZED)
    (asserts! (get authorized officer-info) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get checkpoint-id officer-info) checkpoint-id) ERR-NOT-AUTHORIZED)
    (asserts! (get active checkpoint-info) ERR-INVALID-INPUT)
    (asserts! (> passport-id u0) ERR-DOCUMENT-INVALID)

    (map-set border-crossings
      { crossing-id: crossing-id }
      {
        passport-id: passport-id,
        visa-id: none,
        checkpoint-id: checkpoint-id,
        country: (get country checkpoint-info),
        crossing-type: "exit",
        timestamp: current-block-height,
        immigration-officer: tx-sender,
        status: "approved",
        notes: none,
        biometric-hash: biometric-hash
      }
    )

    (match traveler-info
      info (map-set traveler-status
             { passport-id: passport-id }
             (merge info { status: "departed" })
           )
      (map-set traveler-status
        { passport-id: passport-id }
        {
          current-country: "",
          entry-date: u0,
          status: "departed"
        }
      )
    )

    (var-set next-crossing-id (+ crossing-id u1))
    (ok crossing-id)
  )
)

(define-public (flag-crossing
  (crossing-id uint)
  (notes (string-ascii 200))
)
  (let
    (
      (crossing-data (unwrap! (map-get? border-crossings { crossing-id: crossing-id }) ERR-CROSSING-NOT-FOUND))
      (officer-info (unwrap! (map-get? immigration-officers { officer: tx-sender }) ERR-NOT-AUTHORIZED))
    )
    (asserts! (var-get contract-active) ERR-NOT-AUTHORIZED)
    (asserts! (get authorized officer-info) ERR-NOT-AUTHORIZED)

    (map-set border-crossings
      { crossing-id: crossing-id }
      (merge crossing-data {
        status: "flagged",
        notes: (some notes)
      })
    )
    (ok true)
  )
)

;; Query Functions
(define-read-only (get-crossing-details (crossing-id uint))
  (map-get? border-crossings { crossing-id: crossing-id })
)

(define-read-only (get-traveler-status (passport-id uint))
  (map-get? traveler-status { passport-id: passport-id })
)

(define-read-only (is-traveler-present (passport-id uint) (country (string-ascii 50)))
  (let
    (
      (status-info (map-get? traveler-status { passport-id: passport-id }))
    )
    (match status-info
      info (and
             (is-eq (get current-country info) country)
             (is-eq (get status info) "present")
           )
      false
    )
  )
)

(define-read-only (get-checkpoint-info (checkpoint-id (string-ascii 50)))
  (map-get? authorized-checkpoints { checkpoint-id: checkpoint-id })
)

;; Helper Functions
(define-read-only (is-authorized-officer (officer principal))
  (default-to false (get authorized (map-get? immigration-officers { officer: officer })))
)

(define-read-only (get-officer-checkpoint (officer principal))
  (get checkpoint-id (map-get? immigration-officers { officer: officer }))
)

;; Initialize contract
(map-set immigration-officers
  { officer: CONTRACT-OWNER }
  { authorized: true, checkpoint-id: "ADMIN", badge-number: "ADMIN001" }
)
