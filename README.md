# Rent & Reuse — Campus Sharing Platform v3

A student-friendly campus platform for borrowing, renting and reusing useful items.

## V3 improvements
- Student Sign in / Sign up interface
- Separate student records for profile, department, year, hostel, email and phone
- Student profile and sign-out flow
- Contact details shown through a controlled contact flow after an accepted exchange
- Item photo capture on supported phones
- Gallery photo selection and preview
- Automatic photo compression for browser storage
- Better item condition options: New, Like New, Excellent, Good, Fair, Needs Repair
- Borrow vs Rent flow
- Request → Accept/Reject workflow
- Requirement board for “I need something”
- Wishlist/favorites
- Verified-student and trust/safety UI
- Responsive mobile/desktop design
- Local browser persistence

## Technology
HTML, CSS and vanilla JavaScript.

The current prototype keeps a separate `students` collection inside browser storage and keeps the session separately. This demonstrates the data model and user flow without requiring a server.

## Important production note
This is still a front-end prototype. Browser storage is not a secure real database and the demo authentication must not be used for real credentials. For production, connect the student, item, request, contact and review data to a secure backend such as Supabase or Firebase, use proper password hashing/authentication, access rules and server-side validation.

## GitHub Pages
The repository deploys automatically from `main` using GitHub Actions.

Expected URL:
https://intensiveblack297-tech.github.io/rent-reuse-campus/
